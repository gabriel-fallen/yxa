%%%-------------------------------------------------------------------
%%% File    : sipdst.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Functions to resolve URL's or Via headers into sipdst
%%%           records.
%%% Created : 15 Apr 2004 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(sipdst).
%%-compile(export_all).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 url_to_dstlist/2,
	 url_to_dstlist/3,
	 get_response_destination/1,
	 dst2str/1,
	 debugfriendly/1,

	 test/0
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("sipsocket.hrl").


%%====================================================================
%% External functions
%%====================================================================


%%--------------------------------------------------------------------
%% Function: url_to_dstlist(URL, ApproxMsgSize, ReqURI)
%%           url_to_dstlist(URL, ApproxMsgSize)
%%           URL           = sipurl record(), the destination we
%%                           should resolve
%%           ApproxMsgSize = integer()
%%           ReqURI        = sipurl record(), the Request-URI to use
%%                           when sending a request to this transport-
%%                           layer destination
%% Descrip.: Make a list of sipdst records from an URL. We need the
%%           approximate message size to determine if we can use
%%           UDP or have to do TCP only.
%% Returns : list() of sipdst record() | {error, Reason}
%%--------------------------------------------------------------------
url_to_dstlist(URL, ApproxMsgSize) when is_record(URL, sipurl), is_integer(ApproxMsgSize) ->
    url_to_dstlist(URL, ApproxMsgSize, URL).

url_to_dstlist(URL, ApproxMsgSize, ReqURI) when is_record(URL, sipurl), is_integer(ApproxMsgSize),
						is_record(ReqURI, sipurl) ->
    url_to_dstlist(URL, ApproxMsgSize, ReqURI, false).

url_to_dstlist(URL, ApproxMsgSize, ReqURI, Test) when is_record(URL, sipurl), is_integer(ApproxMsgSize),
						      is_record(ReqURI, sipurl), is_boolean(Test) ->
    case url_param:find(URL#sipurl.param_pairs, "maddr") of
	[MAddr] ->
	    %% RFC3261 #16.5 (Determining Request Targets) says that we MUST use maddr if
	    %% it is set. We do that carefully by checking that it is usable and falling
	    %% back to non-maddr routing if it is not.
	    logger:log(debug, "url_to_dstlist: URL has maddr parameter, trying to make use of it"),
	    MAddrURL = sipurl:set([{host, MAddr}], URL),
	    case url_to_dstlist2(MAddrURL, ApproxMsgSize, ReqURI, Test) of
		{error, Reason} ->
		    logger:log(normal, "Warning: Unusable 'maddr' parameter in URI ~p, ignoring : ~p",
			       [sipurl:print(URL), Reason]),
		    url_to_dstlist2(URL, ApproxMsgSize, ReqURI, Test);
		L when is_list(L) ->
		    L
	    end;
	_ ->
	    url_to_dstlist2(URL, ApproxMsgSize, ReqURI, Test)
    end.

%%--------------------------------------------------------------------
%% Function: url_to_dstlist2(URL, ApproxMsgSize, ReqURI, Test)
%%           URL           = sipurl record(), the destination we
%%                           should resolve
%%           ApproxMsgSize = integer()
%%           ReqURI_in     = sipurl record(), the Request-URI to use
%%                           when sending a request to this transport-
%%                           layer destination
%%           Test          = bool(), testing or not?
%% Descrip.: Make a list of sipdst records from an URL. We need the
%%           approximate message size to determine if we can use
%%           UDP or have to do TCP only.
%% Returns : list() of sipdst record() | {error, Reason}
%%--------------------------------------------------------------------
url_to_dstlist2(URL, ApproxMsgSize, ReqURI_in, Test) when is_record(URL, sipurl), is_integer(ApproxMsgSize),
                                                          is_record(ReqURI_in, sipurl) ->
    DstList = url_to_dstlist3(URL, ApproxMsgSize, ReqURI_in, Test),

    %% For SIPS URI, we MUST remove any destination that is not TLS or known to be
    %% protected through some TLS equivalent mechanism (like IPsec). We should never
    %% end up with any non-TLS destinations for a SIPS URL, but we play it safe here.
    case (URL#sipurl.proto == "sips") of
	true ->
	    remove_non_tls_destinations(DstList);
	false ->
	    DstList
    end.

url_to_dstlist3(URL, ApproxMsgSize, ReqURI_in, Test) when is_record(URL, sipurl), is_integer(ApproxMsgSize),
							  is_record(ReqURI_in, sipurl) ->
    %% Upgrade ReqURI to SIPS if URL is SIPS
    ReqURI =
	case {URL#sipurl.proto, ReqURI_in#sipurl.proto} of
	    {"sips", "sip"} -> sipurl:set([{proto, "sips"}], ReqURI_in);
	    {"sips", "sips"} -> ReqURI_in;
	    {"sips", _} ->
		Msg = io_lib:format("Can't upgrade unknown protocol ~p to SIPS", [ReqURI_in#sipurl.proto]),
		erlang:error({error, lists:flatten(Msg)});
	    _ ->
		ReqURI_in
	end,

    Host = URL#sipurl.host,
    %% Check if URL host is either IPv4 or IPv6 address.
    %% Note: inet_parse:address/1 is not a supported Erlang/OTP function
    case inet_parse:address(util:remove_v6_brackets(Host)) of
	{ok, _IPtuple} ->
	    Port = sipurl:get_port(URL),
	    logger:log(debug, "url_to_dstlist: ~p is an IP address, not performing domain NAPTR/SRV lookup", [Host]),
	    Proto = decide_transport(URL, ApproxMsgSize),
	    case address_to_address_and_proto(Host, Proto) of
		{error, E} ->
		    logger:log(debug, "Warning: Could not make a '~p' destination of ~p:~p (~p)",
			       [Proto, Host, Port, E]),
		    {error, "Coult not make destination out of URL"};
		{ok, UseAddr, UseProto} ->
		    UsePort = sipsocket:default_port(UseProto, Port),
		    %% We don't fill in sipdst.ssl_names here since we are extremely unlikely
		    %% to encounter a SSL certificate for an IP address anyways.
		    [#sipdst{proto	= UseProto,
			     addr	= UseAddr,
			     port	= UsePort,
			     uri	= ReqURI
			    }]
	    end;
	_ ->
	    url_to_dstlist_not_ip(URL, ApproxMsgSize, ReqURI, Test)
    end.

%%--------------------------------------------------------------------
%% Function: get_response_destination(TopVia)
%%           TopVia = via record()
%% Descrip.: Turn the top Via header from a response into a sipdst
%%           record with the protocol, host and port the response
%%           should be sent to.
%% Returns : sipdst record() |
%%           error
%%--------------------------------------------------------------------
get_response_destination(TopVia) when is_record(TopVia, via) ->
    case get_response_host_proto(TopVia) of
        {ok, Host, Proto} ->
            {ViaPort, Parameters} = {TopVia#via.port, TopVia#via.param},
	    ParamDict = sipheader:param_to_dict(Parameters),
	    Port = case dict:find("rport", ParamDict) of
                       {ok, []} ->
                           %% This must be an error response generated before the rport fix-up. Ignore rport.
                           sipsocket:default_port(Proto, ViaPort);
		       {ok, Rport} ->
                           list_to_integer(Rport);
                       _ ->
                           sipsocket:default_port(Proto, ViaPort)
                   end,
	    #sipdst{proto = Proto,
		    addr  = Host,
		    port  = Port
		   };
	_ ->
	    error
    end.

%%--------------------------------------------------------------------
%% Function: dst2str(Dst)
%%           Dst = sipdst record()
%% Descrip.: Turn a sipdst into something printable (for debugging)
%% Returns : DstString, Dst as string()
%%--------------------------------------------------------------------
dst2str(Dst) when is_record(Dst, sipdst) ->
    Proto = Dst#sipdst.proto,
    Addr =
	case (Proto == tcp6 orelse Proto == udp6 orelse Proto == tls6 orelse Proto == yxa_test6) of
	    true ->
		["[", util:remove_v6_brackets(Dst#sipdst.addr), "]"];
	    false ->
		Dst#sipdst.addr
	end,
    Str =
	case Dst#sipdst.uri of
	    undefined ->
		%% No URI, for example Response sipdst record
		io_lib:format("~p:~s:~p", [Proto, Addr, Dst#sipdst.port]);
	    URI when is_record(URI, sipurl) ->
		io_lib:format("~p:~s:~p (~s)", [Proto, Addr, Dst#sipdst.port, sipurl:print(URI)])
	end,
    lists:flatten(Str).

debugfriendly(Dst) when is_record(Dst, sipdst) ->
    debugfriendly2([Dst], []);
debugfriendly(L) ->
    debugfriendly2(L, []).

debugfriendly2([], Res) ->
    lists:reverse(Res);
debugfriendly2([H|T], Res) when is_record(H, sipdst) ->
    Str = dst2str(H),
    debugfriendly2(T, [Str | Res]).


%%====================================================================
%% Internal functions
%%====================================================================


%%--------------------------------------------------------------------
%% Function: url_to_dstlist_not_ip(URL, ApproxMsgSize, ReqURI, Test)
%%           URL           = sipurl record(), destination
%%           ApproxMsgSize = integer()
%%           ReqURI        = sipurl record(), original Request-URI
%%           Test          = bool(), unit testing or not?
%% Descrip.: Called from url_to_dstlist/1 when the Host part of the
%%           URI was not an IP address
%% Returns : DstList         |
%%           {error, Reason}
%%           DstList = list() of sipdst record()
%%--------------------------------------------------------------------
url_to_dstlist_not_ip(URL, ApproxMsgSize, ReqURI, Test) when is_record(URL, sipurl), is_integer(ApproxMsgSize),
							     is_record(ReqURI, sipurl), is_boolean(Test) ->
    Port = sipurl:get_port(URL),
    url_to_dstlist_not_ip2(URL, ApproxMsgSize, ReqURI, Port, Test).

%%
%% URL port specified
%%
url_to_dstlist_not_ip2(URL, ApproxMsgSize, ReqURI, Port, Test)
  when is_record(URL, sipurl), is_integer(ApproxMsgSize), is_integer(Port), is_record(ReqURI, sipurl),
       is_boolean(Test) ->
    %% RFC3263 #4.1 (Selecting a Transport Protocol) "Similarly, if no transport protocol is specified,
    %% and the TARGET is not numeric, but an explicit port is provided, the client SHOULD use UDP for a
    %% SIP URI, and TCP for a SIPS URI"
    UseProto = decide_transport(URL, ApproxMsgSize),
    logger:log(debug, "Resolver: Port was explicitly supplied, size is ~p, will use protocol '~p'",
	       [ApproxMsgSize, UseProto]),
    host_port_to_dstlist(UseProto, URL#sipurl.host, Port, ReqURI, Test);

%%
%% URL port NOT specified, do NAPTR/SRV lookup on host from URL
%%
url_to_dstlist_not_ip2(URL, ApproxMsgSize, ReqURI, Port = none, Test)
  when is_record(URL, sipurl), is_integer(ApproxMsgSize), is_record(ReqURI, sipurl) ->
    %% RFC3263 #4.1 "Otherwise, if no transport protocol or port is specified, and the target is not
    %% a numeric IP address, the client SHOULD perform a NAPTR query for the domain in the URI.".
    case dnsutil_siplookup(URL#sipurl.host, Test) of
	{error, nxdomain} ->
	    %% A SRV-lookup of the Host part of the URL returned NXDOMAIN, this is
	    %% not an error and we will now try to resolve the Host-part directly
	    %% (look for A or AAAA record)
	    {UseProto, UsePort} =
		case URL#sipurl.proto == "sips" of
		    true ->
			SipsPort = sipsocket:default_port("sips", Port),
			logger:log(debug, "Warning: ~p has no NAPTR/SRV records in DNS, but input was a SIPS URI. "
				   "Resolving hostname and trying TLS only.", [URL#sipurl.host]),
			{tls, SipsPort};
		    false ->
			Proto1 =
			    case get_transport_param(URL) of
				tcp -> tcp;
				tls -> tls;
				udp -> udp;
				none ->
				    R = case ApproxMsgSize > 1200 of
					    true  -> tcp;
					    false -> udp
					end,
				    logger:log(debug, "Warning: ~p has no NAPTR/SRV records in DNS, and the "
					       "message size is ~p bytes. Resolving hostname and trying "
					       "'~p' only.", [ApproxMsgSize, URL#sipurl.host, R]),
				    R
			    end,
			SipPort = sipsocket:default_port(Proto1, Port),
			{Proto1, SipPort}
		end,
	    host_port_to_dstlist(UseProto, URL#sipurl.host, UsePort, ReqURI, Test);
	{error, What} ->
	    {error, What};
	SrvList when is_list(SrvList) ->
	    SrvList2 =
		case yxa_config:get_env(tls_disable_client) of
		    {ok, true} ->
			remove_tls_destinations(SrvList);
		    {ok, false} ->
			SrvList
		end,

	    %% In case the client specified a transport parameter, we now try to accomodate that.
	    %% If the client did not specify a transport parameter, we pick all the records of the
	    %% most preferred transport in DNS (that we support, we have conditionally removed all TLS
	    %% destinations above if the TLS client is disabled)
	    SrvList3 = keep_only_best_transport(URL, SrvList2),

	    HostIn = URL#sipurl.host,
	    format_siplookup_result(Port, ReqURI, HostIn, SrvList3, Test)
    end.

%% part of url_to_dstlist_not_ip2/5
%% Returns : NewSRVList = list() of sipdns_srv record()
keep_only_best_transport(URL, SRVList) when is_record(URL, sipurl), is_list(SRVList) ->
    BestProto =
	case (URL#sipurl.proto == "sips") of
	    true ->
		%% Input URL was SIPS, tls is the only acceptable transport
		tls;
	    false ->
		%% get the most prefered transport for the server, indicated by DNS ordering
		case get_transport_param(URL) of
		    none ->
			case SRVList of
			    [#sipdns_srv{proto = FirstProto} | _] ->
				FirstProto;
			    _ ->
				%% value here does not matter, since SRVList is not a list of srv records
				error
			end;
		    TransportProto ->
			TransportProto
		end
	end,

    %% proto in sipdns_srv records are only tcp/udp/tls, never the v6 variants
    [E || E <- SRVList, is_record(E, sipdns_srv), E#sipdns_srv.proto == BestProto].

%%--------------------------------------------------------------------
%% Function: decide_transport(URI, ApproxMsgSize)
%%           URI = sipurl record()
%%           ApproxMsgSize = integer()
%% Descrip.: Figure out which protocol to use based on any present
%%           transport URI parameters, or the message size.
%% Returns : Proto = tcp | udp | tls
%%--------------------------------------------------------------------
decide_transport(URI, ApproxMsgSize) ->
    case {get_proto_from_parameters(URI), URI#sipurl.proto} of
	{tcp, "sips"} -> tls;
	{tcp, _Proto} -> tcp;

	{tls, _Proto} -> tls;

	{udp, "sips"} ->
	    logger:log(debug, "url_to_dstlist: Ignoring explicit transport=udp for SIPS URI - won't work"),
	    tls;

	_ ->
	    case ApproxMsgSize > 1200 of
		true  ->
		    logger:log(debug, "url_to_dstlist: Was going to use UDP, but size requires TCP"),
		    tcp;
		false ->
		    udp
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_proto_from_parameters(URL)
%%           URL = sipurl record()
%% Descrip.: Extract value of a "transport=xxx" Request-URI paramter.
%% Returns : Proto = tcp | udp | tls
%%--------------------------------------------------------------------
get_proto_from_parameters(URL) when is_record(URL, sipurl) ->
    %% Find requested transport in URL parameters and lowercase it
    case get_transport_param(URL) of
	none ->
	    %% RFC3263 #4.1 (Selecting a Transport Protocol) "Otherwise, if no transport
	    %% protocol is specified, but the TARGET is a numeric IP address, the client
	    %% SHOULD use UDP for a SIP URI, and TCP for a SIPS URI
	    case (URL#sipurl.proto == "sips") of
		true  -> tls;
		false -> udp
	    end;
	Proto ->
	    Proto
    end.

get_transport_param(URL) when is_record(URL, sipurl) ->
    case url_param:find(URL#sipurl.param_pairs, "transport") of
	[Transport] ->
	    case httpd_util:to_lower(Transport) of
		"tcp" -> tcp;
		"udp" -> udp;
		"tls" -> tls;
		Unknown ->
		    logger:log(debug, "url_to_dstlist: Request-URI transport parameter value unknown : ~p",
			       [Unknown]),
		    none
	    end;
	_ ->
	    none
    end.

%%--------------------------------------------------------------------
%% Function: combine_host_portres(In)
%%           In = list() of sipdst record() | {error, Reason} tuple()
%% Descrip.: Weed out the sipdst records (if any) from In, preserving
%%           order. If there are only {error, Reason} tuples, return
%%           the first one.
%% Returns : list() of sipdst record() |
%%           {error, Reason}
%%           Reason = term()
%%--------------------------------------------------------------------
combine_host_portres(In) when is_list(In) ->
    combine_host_portres2(lists:flatten(In), [], []).

combine_host_portres2([{error, _Reason} = H | T], Res, ERes) ->
    %% error, put in ERes
    combine_host_portres2(T, Res, [H | ERes]);
combine_host_portres2([H | T], Res, ERes) when is_record(H, sipdst) ->
    %% non-error, put in Res
    combine_host_portres2(T, [H | Res], ERes);
combine_host_portres2([], [], ERes) ->
    %% no more input, and nothing in res - return the first error
    [FirstError | _] = lists:reverse(ERes),
    FirstError;
combine_host_portres2([], Res, _ERes) ->
    %% no more input, and something in Res (we know that since the above
    %% function declaration would have matched on Res = [].
    lists:reverse(Res).

%%--------------------------------------------------------------------
%% Function: remove_tls_destinations(SRVList)
%%           SRVList = list() of sipdns_srv record()
%% Descrip.: Remove all records having proto 'tls' | tls6 from In, and
%%           return a new list() of sipdns_srv record().
%% Returns : DstList = list() of sipdns_srv record().
%%--------------------------------------------------------------------
remove_tls_destinations(SRVList) ->
    remove_tls_destinations2(SRVList, []).

remove_tls_destinations2([], Res) ->
    lists:reverse(Res);
remove_tls_destinations2([#sipdns_srv{proto = Proto} = H | T], Res) when Proto /= tls, Proto /= tls6 ->
    remove_tls_destinations2(T, [H | Res]);
remove_tls_destinations2([H | T], Res) when is_record(H, sipdns_srv) ->
    %% Proto is tls or tls6
    {Proto, Host, Port} = {H#sipdns_srv.proto, H#sipdns_srv.host, H#sipdns_srv.port},
    logger:log(debug, "Resolver: Removing TLS destination ~p:~s:~p from result set since "
	       "TLS client is not enabled", [Proto, Host, Port]),
    remove_tls_destinations2(T, Res).


%%--------------------------------------------------------------------
%% Function: remove_non_tls_destinations(In)
%%           In = list() of sipdst record()
%% Descrip.: Remove all records NOT having proto 'tls' | tls6 from In,
%%           and return a new list() of sipdst record().
%% Returns : DstList = list() of sipdst record()
%%--------------------------------------------------------------------
remove_non_tls_destinations(In) ->
    case remove_non_tls_destinations2(In, 0, []) of
	{ok, 0, _Res} ->
	    In;
	{ok, RemoveCount, Res} ->
	    logger:log(debug, "Resolver: Removed ~p non-TLS destinations", [RemoveCount]),
	    Res
    end.

remove_non_tls_destinations2([], RCount, Res) ->
    {ok, RCount, lists:reverse(Res)};
remove_non_tls_destinations2([#sipdst{proto = Proto} = H | T], RCount, Res) when Proto == tls; Proto == tls6 ->
    remove_non_tls_destinations2(T, RCount, [H | Res]);
remove_non_tls_destinations2([H | T], RCount, Res) when is_record(H, sipdst) ->
    %% Proto is NOT tls or tls6, check if we should consider it a secure destination anyways
    %% (for example, it might be protected by IPsec)
    #sipdst{proto = Proto,
	    addr  = Host,
	    port  = Port
	   } = H,

    case local:is_tls_equivalent(Proto, Host, Port) of
	true ->
	    %% host:port is protected by some TLS equivalent mechanism
	    remove_non_tls_destinations2(T, RCount, [H | Res]);
	X when X == false; X == undefined ->
	    remove_non_tls_destinations2(T, RCount + 1, Res)
    end.

%%--------------------------------------------------------------------
%% Function: host_port_to_dstlist(Proto, InHost, InPort, URI, Test)
%%           host_port_to_dstlist(Proto, InHost, InPort, URI,
%%                                SSLNames, Test)
%%           Proto    = atom(), tcp | udp | tls | yxa_test
%%           Host     = string()
%%           Port     = integer() | none
%%           URI      = sipurl record() to put in the created sipdst
%%                      records
%%           SSLNames = list() of string(), SSL certname(s) to expect
%%           Test     = bool(), unit testing or not?
%% Descrip.: Resolves a hostname and returns a list of sipdst
%%           records of the protocol requested.
%%           InPort should either be an integer, or the atom 'none'
%%           to use the default port for the protocol.
%% Returns : DstList         |
%%           {error, Reason}
%%           DstList = list() of sipdst record()
%%--------------------------------------------------------------------
host_port_to_dstlist(Proto, Host, Port, URI, Test) ->
    host_port_to_dstlist(Proto, Host, Port, URI, [Host], Test).

host_port_to_dstlist(Proto, Host, Port, URI, SSLNames, Test) when (is_integer(Port) orelse Port == none),
								  is_record(URI, sipurl), is_list(SSLNames),
								  is_boolean(Test) ->
    case dnsutil_get_ip_port(Host, Port, Test) of
	{error, What} ->
	    {error, What};
	L when is_list(L) ->
	    %% L is a list of sipdns_hostport record()
	    make_sipdst_from_hostport(Proto, URI, SSLNames, L)
    end.

%%--------------------------------------------------------------------
%% Function: make_sipdst_from_hostport(Proto, URI, SSLNames, In)
%%           Proto    = atom(), tcp | udp | tls
%%           URI      = sipurl record(), URI to stick into the
%%                      resulting sipdst records
%%           SSLNames = list() of string(), hostnames to validate SSL
%%                      certificate subjectAltName/CN against
%%           In       = list() of sipdns_hostport record() - typically
%%                      the result of a call to dnsutil:get_ip_port()
%% Descrip.: Turns the result of a dnsutil:get_ip_port() into a list
%%           of sipdst records. get_ip_port() return a list of
%%           sipdns_hostport records where the addr element is a
%%           string ("10.0.0.1", "[2001:6b0:5:987::1]"). The family
%%           element is 'inet' or 'inet6' and we need to know to
%%           convert Proto as necessary. The order of the input tuples
%%           is preserved in the resulting list.
%% Returns : DstList | {error, Reason}
%%           DstList = list() of sipdst record()
%%           Reason  = string()
%%--------------------------------------------------------------------
make_sipdst_from_hostport(Proto, URI, SSLNames, In) when (Proto == tcp orelse Proto == udp
							  orelse Proto == tls orelse Proto == yxa_test),
							 is_record(URI, sipurl), is_list(SSLNames), is_list(In) ->
    UseSSLNames = case Proto == tls of
		      true -> SSLNames;
		      false -> []
		  end,
    make_sipdst_from_hostport2(Proto, URI, UseSSLNames, In, []).

%%
%% sipdns_hostport.family == inet
%%
make_sipdst_from_hostport2(Proto, URI, SSLNames, [#sipdns_hostport{family = inet} = H | T], Res) ->
    UsePort = sipsocket:default_port(Proto, H#sipdns_hostport.port),
    This = #sipdst{proto	= Proto,
		   addr		= H#sipdns_hostport.addr,
		   port		= UsePort,
		   uri		= URI,
		   ssl_names	= SSLNames
		  },
    make_sipdst_from_hostport2(Proto, URI, SSLNames, T, [This | Res]);
%%
%% sipdns_hostport.family == inet6
%%
make_sipdst_from_hostport2(Proto, URI, SSLNames, [#sipdns_hostport{family = inet6} = H | T], Res) ->
    %% inet6 family, must turn Proto into IPv6 variant
    UseProto = case Proto of
		   tcp -> tcp6;
		   udp -> udp6;
		   tls -> tls6;
		   yxa_test -> yxa_test6
	       end,
    UsePort = sipsocket:default_port(UseProto, H#sipdns_hostport.port),
    This = #sipdst{proto	= UseProto,
		   addr		= H#sipdns_hostport.addr,
		   port		= UsePort,
		   uri		= URI,
		   ssl_names	= SSLNames
		  },
    make_sipdst_from_hostport2(Proto, URI, SSLNames, T, [This | Res]);
%%
%% No more input
%%
make_sipdst_from_hostport2(_Proto, _URI, _SSLNames, [], Res) ->
    lists:reverse(Res).


%%--------------------------------------------------------------------
%% Function: format_siplookup_result(InPort, ReqURI, HostIn, DstList,
%%                                   Test)
%%           InPort  = integer() | none
%%           ReqURI  = sipurl record()
%%           HostIn  = string() | undefined, the hostname (or
%%                     domain name) we got as input
%%           SrvList = list() of sipdns_srv record()
%%           Test    = bool(), unit testing or not?
%% Descrip.: Turns the result of a dnsutil:siplookup() into a list
%%           of sipdst records. The ordering is preserved.
%% Returns : DstList, list() of sipdst record()
%%--------------------------------------------------------------------
format_siplookup_result(InPort, ReqURI, HostIn, SrvList, Test)
  when (is_integer(InPort) orelse InPort == none), is_record(ReqURI, sipurl),
       (is_list(HostIn) orelse HostIn == undefined), is_list(SrvList) ->
    SSLNames = [HostIn],
    {ok, AllowServerName} = yxa_config:get_env(ssl_check_subject_altname_allow_servername),
    format_siplookup_result2(InPort, ReqURI, SSLNames, AllowServerName, Test, SrvList, []).

format_siplookup_result2(_InPort, _ReqURI, _SSLNames, _SSL_AddHost, _Test, [], Res) ->
    Res;
format_siplookup_result2(InPort, ReqURI, SSLNames, SSL_AddHost, Test, [H | T], Res) when is_record(H, sipdns_srv) ->
    {Proto, Host, Port} = {H#sipdns_srv.proto, H#sipdns_srv.host, H#sipdns_srv.port},
    %% If InPort is 'none', then use the port from DNS. Otherwise, use InPort.
    %% This is to handle if we for example receive a request with a Request-URI of
    %% sip.example.net:5070, and sip.example.net has SRV-records saying port 5060. In
    %% that case, we should still send our request to port 5070.
    UsePort = case InPort of
		  _ when is_integer(InPort) -> InPort;
		  none -> Port
	      end,
    if
	UsePort /= Port ->
	    logger:log(debug, "Warning: ~p is specified to use port ~p in DNS,"
		       " but I'm going to use the supplied port ~p instead",
		       [Host, Port, UsePort]);
	true -> true
    end,

    AllSSLNames = format_siplookup_result2_sslnames(Proto, SSLNames, SSL_AddHost, Host),

    %% XXX what if host_port_to_dstlist for this hostname returns a sipdst-record with a
    %% different address (because of DNS round-robin, or DNS TTL reaching zero) the second
    %% time we query for the very same hostname returned in a siplookup result set?
    NewRes =
	case host_port_to_dstlist(Proto, Host, UsePort, ReqURI, AllSSLNames, Test) of
	    {error, Reason} ->
		logger:log(error, "Warning: Could not make DstList out of ~p:~p:~p : ~p",
			   [Proto, Host, UsePort, Reason]),
		Res;
	    L when is_list(L) ->
		Res ++ L
	end,
    format_siplookup_result2(InPort, ReqURI, SSLNames, SSL_AddHost, Test, T, NewRes).


%%--------------------------------------------------------------------
%% Function: format_siplookup_result2_sslnames(Proto, SSLNames,
%%                                             AddHost, Host)
%%           Proto    = tls | tls6 | ...
%%           SSLNames = list() of string(), extra SSL names to allow
%%           AddHost  = bool()
%%           Host     = string(), hostname we are resolving
%% Descrip.: Determine what we will later use to validate the SSL
%%           connection made. The default is to use SSLNames (which is
%%           typically what a user entered as domain-name in a URL),
%%           but it is very common to have a per-server certificate,
%%           so if configured to we will also allow the hostname from
%%           the NAPTR/SRV lookup. This is of course less secure,
%%           unless the NAPTR/SRV DNS lookup is secured using DNSSEC.
%% Returns : AllSSLNames = list() of string()
%%--------------------------------------------------------------------
format_siplookup_result2_sslnames(Proto, SSLNames, true, Host) when Proto == tls; Proto == tls6 ->
    %% AddHost is true, return SSLNames and Host merged together
    L = [Host | SSLNames],
    lists:usort(L);
format_siplookup_result2_sslnames(Proto, SSLNames, false, _Host) when Proto == tls; Proto == tls6 ->
    %% AddHost is false, just return SSLNames
    SSLNames;
format_siplookup_result2_sslnames(_Proto, _SSLNames, _AddHost, _Host) ->
    %% Not TLS, no reason to construct a list of validation names
    [].


%%--------------------------------------------------------------------
%% Function: get_response_host_port(TopVia)
%%           TopVia = via record()
%% Descrip.: Argument is the top Via header in a response, this
%%           function extracts the destination and protocol we
%%           should use.
%% Returns : {ok, Address, Proto} |
%%           error
%%           Address = string() that might be IPv4 address (from
%%                     received=), IPv6 address (from received=), or
%%                     whatever was in the host part of the Via.
%%           Proto   = atom(), tcp | udp | tcp6 | udp6 | tls | tls6
%%--------------------------------------------------------------------
get_response_host_proto(TopVia) when is_record(TopVia, via) ->
    {Protocol, Host, Parameters} = {TopVia#via.proto, TopVia#via.host, TopVia#via.param},
    ParamDict = sipheader:param_to_dict(Parameters),
    Proto = sipsocket:viastr2proto(Protocol),
    case dict:find("received", ParamDict) of
	{ok, Received} ->
	    case address_to_address_and_proto(Received, Proto) of
		{error, E1} ->
		    logger:log(debug, "Warning: Malformed received= parameter (~p) : ~p", [Received, E1]),
		    %% received= parameter not usable, try host part of Via instead
		    %% XXX try to resolve host part of Via if necessary
		    case address_to_address_and_proto(Host, Proto) of
			{error, E2} ->
			    logger:log(debug, "Warning: Invalid host part of Via (~p) : ~p", [Host, E2]),
			    logger:log(error, "Failed getting a response destination out of Via : ~p", [TopVia]),
			    error;
			{ok, Address1, Proto1} ->
			    {ok, Address1, Proto1}
		    end;
		{ok, Address1, Proto1} ->
		    {ok, Address1, Proto1}
	    end;
	error ->
	    %% There was no received= parameter. Do the same checks but on the Via
	    %% hostname (which is then almost certainly an IP-address).
	    case address_to_address_and_proto(Host, Proto) of
		{error, E1} ->
		    logger:log(debug, "Warning: No received= and invalid host part of Via (~p) : ~p", [Host, E1]),
		    logger:log(error, "Failed getting a response destination out of Via : ~p", [TopVia]),
		    error;
		{ok, Address1, Proto1} ->
		    {ok, Address1, Proto1}
	    end
    end.


%%--------------------------------------------------------------------
%% Function: address_to_address_and_proto(Addr, DefaultProto)
%%           Addr = term(), something (probably a string()) that is
%%                  parseable by inet_parse:ipv{4,6}_address() (should
%%                  be an IPv4 or IPv6 address, not a hostname!)
%%           DefaultProto = atom(), tcp | udp | tls | yxa_test
%% Descrip.: When looking at Via headers, we often have a protocol
%%           from the SIP/2.0/FOO but we need to look at the
%%           address to determine if our sipdst proto should be
%%           foo or foo6. This function does that.
%% Returns : {ok, Address, Proto} |
%%           {error, Reason}
%%           Address = term(), parsed version of Addr
%%           Proto   = atom(), tcp | udp | tcp6 | udp6 | tls | tls6 |
%%                             yxa_test | yxa_test6
%%           Reason  = string()
%% Note    : yxa_test and yxa_test6 are just for YXA unit tests.
%%--------------------------------------------------------------------
address_to_address_and_proto(Addr, DefaultProto) when DefaultProto == tcp; DefaultProto == udp; DefaultProto == tls;
						      DefaultProto == yxa_test ->
    case inet_parse:ipv4_address(Addr) of
	{ok, _IPtuple} ->
	    {ok, Addr, DefaultProto};
	_ ->
	    case yxa_config:get_env(enable_v6) of
		{ok, true} ->
		    %% Check if it matches IPv6 address syntax
		    case inet_parse:ipv6_address(util:remove_v6_brackets(Addr)) of
			{ok, _IPtuple} ->
			    Proto6 = case DefaultProto of
					 tcp -> tcp6;
					 udp -> udp6;
					 tls -> tls6;
					 yxa_test -> yxa_test6
				     end,
			    {ok, Addr, Proto6};
			_ ->
			    {error, "not an IPv4 or IPv6 address"}
		    end;
		{ok, false} ->
		    {error, "not an IPv4 address"}
	    end
    end.


dnsutil_siplookup(In, _Test = false) ->
    dnsutil:siplookup(In);
dnsutil_siplookup(In, _Test = true) ->
    Key = {siplookup, In},
    case get(dnsutil_test_res) of
	L when is_list(L) ->
	    case lists:keysearch(Key, 1, L) of
		{value, {Key, Value} = Entry} ->
		    put(dnsutil_test_res, L -- [Entry]),
		    Value;
		false ->
		    Msg = io_lib:format("Unit test result ~p not found", [Key]),
		    {error, lists:flatten(Msg)}
	    end;
	undefined ->
	    Msg = io_lib:format("Unit test result ~p undefined", [Key]),
	    {error, lists:flatten(Msg)}
    end.

dnsutil_get_ip_port(Host, Port, _Test = false) ->
    dnsutil:get_ip_port(Host, Port);
dnsutil_get_ip_port(Host, Port, _Test = true) ->
    Key = {get_ip_port, Host, Port},
    case get(dnsutil_test_res) of
	L when is_list(L) ->
	    case lists:keysearch(Key, 1, L) of
		{value, {Key, Value} = Entry} ->
		    put(dnsutil_test_res, L -- [Entry]),
		    Value;
		false ->
		    Msg = io_lib:format("Unit test result ~p not found", [Key]),
		    {error, lists:flatten(Msg)}
	    end;
	undefined ->
	    Msg = io_lib:format("Unit test result ~p undefined", [Key]),
	    {error, lists:flatten(Msg)}
    end.



%%====================================================================
%% Test functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: test()
%% Descrip.: autotest callback
%% Returns : ok
%%--------------------------------------------------------------------
test() ->
    Testing = true,
    NotTesting = false,

    %% test remove_tls_destinations(SRVList)
    %%--------------------------------------------------------------------
    TCP4 = #sipdns_srv{proto=tcp, host="192.0.2.1", port=5060},
    UDP4 = #sipdns_srv{proto=udp, host="192.0.2.2", port=5060},
    TLS4 = #sipdns_srv{proto=tls, host="192.0.2.3", port=5061},
    TCP6 = #sipdns_srv{proto=tcp6, host="[2001:6b0:5:987::1]", port=none},
    UDP6 = #sipdns_srv{proto=udp6, host="[2001:6b0:5:987::2]", port=none},
    TLS6 = #sipdns_srv{proto=tls6, host="[2001:6b0:5:987::3]", port=none},

    autotest:mark(?LINE, "remove_tls_destinations/2 - 1"),
    [TCP4, UDP4] = remove_tls_destinations([TCP4, UDP4]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 2"),
    [UDP4] = remove_tls_destinations([UDP4]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 3"),
    [TCP4] = remove_tls_destinations([TCP4, TLS4]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 4"),
    [] = remove_tls_destinations([TLS4]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 5"),
    [] = remove_tls_destinations([TLS6]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 6"),
    [] = remove_tls_destinations([TLS6, TLS4, TLS6, TLS4]),

    autotest:mark(?LINE, "remove_tls_destinations/2 - 7"),
    [TCP6, UDP6] = remove_tls_destinations([TLS6, TCP6, TLS4, UDP6, TLS4]),


    %% test remove_non_tls_destinations(SRVList)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "remove_non_tls_destinations/2 - 1"),
    %% test normal case
    RemoveNonTLS_1 = [#sipdst{proto = tcp}, #sipdst{proto = tls6},
		      #sipdst{proto = udp}, #sipdst{proto = tls}
		     ],
    [#sipdst{proto = tls6}, #sipdst{proto = tls}] =
	remove_non_tls_destinations(RemoveNonTLS_1),

    %% test make_sipdst_from_hostport(Proto, URI, SSLHost, In)
    %%--------------------------------------------------------------------
    URL = sipurl:parse("sip:ft@example.org:1234"),

    autotest:mark(?LINE, "make_sipdst_from_hostport/3 - 1"),
    %% simple case, tcp and no supplied port in the tuple
    HostPort1 = #sipdns_hostport{family=inet, addr="address", port=none},
    Dst1 = #sipdst{proto=tcp, addr="address", port=5060, uri=URL, ssl_names=[]},
    [Dst1] = make_sipdst_from_hostport(tcp, URL, ["ssl1"], [HostPort1]),

    autotest:mark(?LINE, "make_sipdst_from_hostport/3 - 2"),
    %% tcp 'upped' to tcp6 since tuple protocol is inet6. port from tuple used.
    HostPort2 = #sipdns_hostport{family=inet6, addr="address", port=5070},
    Dst2 = #sipdst{proto=tcp6, addr="address", port=5070, uri=URL, ssl_names=[]},
    [Dst2] = make_sipdst_from_hostport(tcp, URL, [], [HostPort2]),

    autotest:mark(?LINE, "make_sipdst_from_hostport/3 - 3"),
    %% mixed
    Dst2_2 = Dst2#sipdst{ssl_names=[]},
    [Dst1, Dst2_2] =
	make_sipdst_from_hostport(tcp, URL, ["ssl1"], [HostPort1, HostPort2]),

    autotest:mark(?LINE, "make_sipdst_from_hostport/3 - 4"),
    %% SSL names
    HostPortL_4 = [#sipdns_hostport{family = inet, addr="secure", port=90}],
    [#sipdst{proto = tls,
	     addr  = "secure",
	     port  = 90,
	     uri   = URL,
	     ssl_names = ["secure", "test"]
	    }] = make_sipdst_from_hostport(tls, URL, ["secure", "test"], HostPortL_4),

    autotest:mark(?LINE, "make_sipdst_from_hostport/3 - 5"),
    HostPortL_5 = [#sipdns_hostport{family = inet6, addr="test6", port = 1}],
    %% Make sure we turn proto into v6 variants like we should
    [#sipdst{proto = tcp6}] = make_sipdst_from_hostport(tcp, URL, [], HostPortL_5),
    [#sipdst{proto = udp6}] = make_sipdst_from_hostport(udp, URL, [], HostPortL_5),
    [#sipdst{proto = tls6}] = make_sipdst_from_hostport(tls, URL, [], HostPortL_5),
    [#sipdst{proto = yxa_test6}] = make_sipdst_from_hostport(yxa_test, URL, [], HostPortL_5),


    %% test get_response_host_proto(TopVia)
    %% NOTE: We can currently only test with IPv4 addresses since IPv6 is
    %% off by default, so when the tests are run enable_v6 might not be
    %% 'true'.
    %%--------------------------------------------------------------------
    GetVia = fun(ViaStr) -> 
		     [Res] = sipheader:via([ViaStr]),
		     Res
	     end,

    autotest:mark(?LINE, "get_response_host_proto/1 - 1"),
    %% straight forward, no received= parameter
    {ok, "192.0.2.1", tcp} = get_response_host_proto(GetVia("SIP/2.0/TCP 192.0.2.1")),

    autotest:mark(?LINE, "get_response_host_proto/1 - 2"),
    %% straight forward, address in received= parameter
    {ok, "192.0.2.1", tcp} = get_response_host_proto(GetVia("SIP/2.0/TCP phone.example.org;received=192.0.2.1")),

    autotest:mark(?LINE, "get_response_host_proto/1 - 3"),
    %% error, hostname in Via host and no received= parameter
    error = get_response_host_proto(GetVia("SIP/2.0/TCP phone.example.org")),

    autotest:mark(?LINE, "get_response_host_proto/1 - 4"),
    %% invalid received= parameter, but luckily valid IP address in Via host
    put(dnsutil_test_res, [{{get_ip_port, "X", none}, {error, timeout}}]),
    {ok, "192.0.2.1", tls} = get_response_host_proto(GetVia("SIP/2.0/TLS 192.0.2.1;received=X")),

    autotest:mark(?LINE, "get_response_host_proto/1 - 5"),
    %% test with invalid received= parameter, and hostname not found in DNS
    put(dnsutil_test_res, [{{get_ip_port, "X", none},			{error, timeout}},
			   {{get_ip_port, "test.example.com", none},	{error, nomatch}}]),
    error = get_response_host_proto(GetVia("SIP/2.0/TLS test.example.com;received=X")),


    %% test get_response_destination(TopVia)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_response_destination/1 - 1"),
    %% test normal case, no port
    #sipdst{proto = tls,
	    addr  = "192.0.2.1",
	    port  = 5061
	    } =
	get_response_destination(GetVia("SIP/2.0/TLS example.com;received=192.0.2.1")),

    autotest:mark(?LINE, "get_response_destination/1 - 2"),
    %% test non-default port
    #sipdst{proto = tcp,
	    addr  = "192.0.2.1",
	    port  = 5012
	    } =
	get_response_destination(GetVia("SIP/2.0/TCP example.com:5012;received=192.0.2.1")),

    autotest:mark(?LINE, "get_response_destination/1 - 3"),
    %% test rport specified
    #sipdst{proto = tcp,
	    addr  = "192.0.2.1",
	    port  = 50121
	    } =
	get_response_destination(GetVia("SIP/2.0/TCP example.com:5012;rport=50121;received=192.0.2.1")),

    autotest:mark(?LINE, "get_response_destination/1 - 4"),
    %% test rport requested but apparently not filled in (should go to default port)
    #sipdst{proto = udp,
	    addr  = "192.0.2.1",
	    port  = 5060
	    } =
	get_response_destination(GetVia("SIP/2.0/UDP example.com;rport;received=192.0.2.1")),

    autotest:mark(?LINE, "get_response_destination/1 - 5"),
    %% test with invalid hostname and no received
    put(dnsutil_test_res, [{{get_ip_port, "example.com", none}, {error, timeout}}]),
    error = get_response_destination(GetVia("SIP/2.0/UDP example.com")),


    %% test format_siplookup_result(InPort, ReqURI, SSLHost, DstList, Test)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "format_siplookup_result/5 - 1"),
    %% InPort 'none', use the one from DNS
    SRV3 = #sipdns_srv{proto=tcp, host="192.0.2.1", port=1234},
    Dst3 = #sipdst{proto=tcp, addr="192.0.2.1", port=1234, uri=URL, ssl_names=[]},
    [Dst3] = format_siplookup_result(none, URL, "192.0.2.1", [SRV3], NotTesting),

    autotest:mark(?LINE, "format_siplookup_result/5 - 2"),
    %% InPort 2345, overrides the one in DNS (1234 in Tuple3)
    Dst4 = #sipdst{proto=tcp, addr="192.0.2.1", port=2345, uri=URL, ssl_names=[]},
    [Dst4] = format_siplookup_result(2345, URL, undefined, [SRV3], NotTesting),

    autotest:mark(?LINE, "format_siplookup_result/5 - 3"),
    SRV5 = #sipdns_srv{proto=tcp, host="192.0.2.2", port=5065},
    Dst5 = #sipdst{proto=tcp, addr="192.0.2.2", port=5065, uri=URL, ssl_names=[]},
    %% more than one tuple in
    [Dst3, Dst5] = format_siplookup_result(none, URL, undefined, [SRV3, SRV5], NotTesting),

    %% test format_siplookup_result2(InPort, ReqURI, SSLNames, SSL_AddHost, DstList, Test)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "format_siplookup_result2/6 - 1"),
    %% test with hostnames, InPort present and SSL_AddHost set
    FSR2_URL_1 = sipurl:parse("sip:u@example.com"),
    FSR2_DNS_1 = [{{get_ip_port, "test.example.com", 100},
		   [#sipdns_hostport{family = inet,
				     addr   = "192.0.2.2",
				     port   = 99
				    }]
		  },
		  {{get_ip_port, "ssl.example.com", 100},
		   [#sipdns_hostport{family = inet,
				     addr   = "192.0.2.3",
				     port   = 99
				    }]
		  }],
    put(dnsutil_test_res, FSR2_DNS_1),
    FSR2_SrvList1 = [#sipdns_srv{proto = udp, host = "test.example.com", port = 99},
		     #sipdns_srv{proto = tls, host = "ssl.example.com", port = 99}],
    [#sipdst{proto	= udp,
	     addr	= "192.0.2.2",
	     port	= 99,
	     uri	= FSR2_URL_1,
	     ssl_names	= []
	    },
     #sipdst{proto	= tls,
	     addr	= "192.0.2.3",
	     port	= 99,
	     uri	= FSR2_URL_1,
	     ssl_names	= ["example.com", "ssl.example.com"]
	    }] =
	format_siplookup_result(100, FSR2_URL_1, "example.com", FSR2_SrvList1, Testing),

    autotest:mark(?LINE, "format_siplookup_result2/6 - 2"),
    %% test with hostnames, InPort present and SSL_AddHost set
    FSR2_URL_1 = sipurl:parse("sip:u@example.com"),
    FSR2_DNS_2 = [{{get_ip_port, "test.example.com", 5060},
		   [#sipdns_hostport{family = inet,
				     addr   = "192.0.2.2",
				     port   = 5060
				    }]
		  },
		  {{get_ip_port, "ssl.example.com", 5061},
		   [#sipdns_hostport{family = inet,
				     addr   = "192.0.2.3",
				     port   = 5061
				    }]
		  }],
    put(dnsutil_test_res, FSR2_DNS_2),
    FSR2_SrvList2 = [#sipdns_srv{proto = udp, host = "test.example.com", port = 5060},
		     #sipdns_srv{proto = tls, host = "ssl.example.com", port = 5061}],
    [#sipdst{proto	= udp,
	     addr	= "192.0.2.2",
	     port	= 5060,
	     uri	= FSR2_URL_1,
	     ssl_names	= []
	    },
     #sipdst{proto	= tls,
	     addr	= "192.0.2.3",
	     port	= 5061,
	     uri	= FSR2_URL_1,
	     ssl_names	= ["example.com", "ssl.example.com"]
	    }] =
	format_siplookup_result(none, FSR2_URL_1, "example.com", FSR2_SrvList2, Testing),

    %% test combine_host_portres(In)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "combine_host_portres/1 - 1"),
    %% test with only a single error
    {error, 1} = combine_host_portres([{error, 1}]),

    autotest:mark(?LINE, "combine_host_portres/1 - 2"),
    %% test with only errors
    {error, 1} = combine_host_portres([{error, 1}, {error, 2}]),

    autotest:mark(?LINE, "combine_host_portres/1 - 3"),
    %% test with errors, and one valid sipdst
    [#sipdst{proto=1}] = combine_host_portres([{error, 1}, {error, 2}, #sipdst{proto=1}]),

    autotest:mark(?LINE, "combine_host_portres/1 - 4"),
    %% test with errors, and two valid sipdst's
    [#sipdst{proto=1}, #sipdst{proto=2}] =
	combine_host_portres([#sipdst{proto=1}, {error, 1}, {error, 2}, #sipdst{proto=2}]),

    autotest:mark(?LINE, "combine_host_portres/1 - 5"),
    %% test with three valid sipdst's only
    [#sipdst{proto=1}, #sipdst{proto=2}, #sipdst{proto=3}] =
	combine_host_portres([[#sipdst{proto=1}, #sipdst{proto=2}], [#sipdst{proto=3}]]),


    %% test get_proto_from_parameters(URL)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "get_proto_from_parameters/1 - 1"),
    %% test that we default to UDP
    udp = get_proto_from_parameters( sipurl:parse("sip:ft@example.org") ),

    autotest:mark(?LINE, "get_proto_from_parameters/1 - 2"),
    %% test UDP protocol specified
    udp = get_proto_from_parameters( sipurl:parse("sip:ft@example.org;transport=UDP") ),

    autotest:mark(?LINE, "get_proto_from_parameters/1 - 3"),
    %% test TCP protocol specified, and strange casing
    tcp = get_proto_from_parameters( sipurl:parse("sip:ft@example.org;transport=tCp") ),

    autotest:mark(?LINE, "get_proto_from_parameters/1 - 4"),
    %% test unknown transport parameter and SIPS URL
    tls = get_proto_from_parameters( sipurl:parse("sips:ft@example.org;transport=foobar") ),

    autotest:mark(?LINE, "get_proto_from_parameters/1 - 4"),
    %% test unknown transport parameter and non-SIPS URL
    udp = get_proto_from_parameters( sipurl:parse("sip:ft@example.org;transport=foobar") ),


    %% test url_to_dstlist(URL, ApproxMsgSize, ReqURI)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "url_to_dstlist/3 - 0"),
    UTD_URL1 = sipurl:parse("sip:user@example.org"),
    UTD_URL1_SIPS =  sipurl:set([{proto, "sips"}], UTD_URL1),

    autotest:mark(?LINE, "url_to_dstlist/3 - 1"),
    %% test with maddr, no transport
    UTD_URL1_1 = sipurl:parse("sip:user@example.org;maddr=192.0.2.9"),
    [#sipdst{proto = udp,
	     addr = "192.0.2.9",
	     port = 5060,
	     uri = UTD_URL1
	    }] = url_to_dstlist(UTD_URL1_1, 1000, UTD_URL1, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 2"),
    %% test with maddr and transport
    UTD_URL2_1 = sipurl:parse("sip:user@example.org;maddr=192.0.2.9;transport=tcp"),
    [#sipdst{proto = tcp,
	     addr = "192.0.2.9",
	     port = 5060,
	     uri = UTD_URL1
	    }] = url_to_dstlist(UTD_URL2_1, 1000, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 3.1"),
    %% test with SIPS protocol
    UTD_URL3_1 = sipurl:parse("sips:user@example.org;maddr=192.0.2.9"),
    [#sipdst{proto = tls,
	     addr = "192.0.2.9",
	     port = 5061,
	     uri = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL3_1, 1000, UTD_URL1, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 3.2"),
    %% test with SIPS protocol and transport=tls parameter (really deprecated)
    UTD_URL3_2 = sipurl:parse("sips:user@example.org;maddr=192.0.2.9;transport=tls"),
    [#sipdst{proto = tls,
	     addr = "192.0.2.9",
	     port = 5061,
	     uri = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL3_2, 1000, UTD_URL1, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 3.3"),
    %% test with SIPS protocol and transport=TCP parameter
    UTD_URL3_3 = sipurl:parse("sips:user@example.org:5066;maddr=192.0.2.9;transport=TCP"),
    [#sipdst{proto = tls,
	     addr = "192.0.2.9",
	     port = 5066,
	     uri = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL3_3, 1000, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 4"),
    %% test with SIPS transport and incompatible transport parameter
    UTD_URL4_1 = sipurl:parse("sips:user@example.org;maddr=192.0.2.9;transport=udp"),
    [#sipdst{proto = tls,
	     addr  = "192.0.2.9",
             port  = 5061
	    }] = url_to_dstlist(UTD_URL4_1, 1000, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 5"),
    %% test with invalid maddr parameter
    UTD_URL5_1 = sipurl:parse("sip:user@192.0.2.8;maddr=test;transport=tcp"),
    put(dnsutil_test_res, [{{siplookup, "test"},		{error, nxdomain}},
			   {{get_ip_port, "test", 5060},	{error, nxdomain}}
			   ]),
    [#sipdst{proto = tcp,
	     addr = "192.0.2.8",
	     port = 5060,
	     uri  = UTD_URL1
	    }] = url_to_dstlist(UTD_URL5_1, 1000, UTD_URL1, Testing),

    %% non-maddr tests

    autotest:mark(?LINE, "url_to_dstlist/3 - 10"),
    %% test with IP address, large size and SIPS protocol
    UTD_URL10_1 = sipurl:parse("sips:user@192.0.2.8"),
    [#sipdst{proto = tls,
	     addr = "192.0.2.8",
	     port = 5061,
	     uri  = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL10_1, 2000, UTD_URL1_SIPS, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 11"),
    %% test with non-IP, port specified, hostname not resolvable
    UTD_URL11_1 = sipurl:parse("sip:user@test.example.com:5012"),
    put(dnsutil_test_res, [{{get_ip_port, "test.example.com", 5012},	{error, nxdomain}}
			   ]),
    {error, nxdomain} = url_to_dstlist(UTD_URL11_1, 1000, UTD_URL1_SIPS, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 12.1"),
    %% test with non-IP, port specified
    UTD_URL12_1 = sipurl:parse("sip:user@test.example.com:5012"),
    put(dnsutil_test_res, [{{get_ip_port, "test.example.com", 5012},
			    [#sipdns_hostport{family = inet,
					      addr   = "192.0.2.2",
					      port   = 5012
					     }]
			   }
			  ]),
    [#sipdst{proto = udp,		%% udp since port was specified
	     addr = "192.0.2.2",
	     port = 5012,
	     uri  = UTD_URL1
	    }] = url_to_dstlist(UTD_URL12_1, 1000, UTD_URL1, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 12.2"),
    %% test with non-IP, port specified
    UTD_URL12_2 = sipurl:parse("sips:user@test.example.com:5012"),
    put(dnsutil_test_res, [{{get_ip_port, "test.example.com", 5012},
			    [#sipdns_hostport{family = inet,
					      addr   = "192.0.2.2",
					      port   = 5012
					     }]
			   }
			  ]),
    [#sipdst{proto = tls,		%% tls (tcp) since port was specified and URI is SIPS
	     addr = "192.0.2.2",
	     port = 5012,
	     uri  = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL12_2, 1000, UTD_URL1_SIPS, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 13.1"),
    %% test with transport=tcp parameter, not SIPS
    UTD_DNS_13_1 = [{{get_ip_port, "test.example.com", 5012},
                            [#sipdns_hostport{family = inet,
                                              addr   = "192.0.2.2",
                                              port   = 5012
                                             }]
		    }
		   ],
    UTD_URL13_1 = sipurl:parse("sip:user@test.example.com:5012;transport=tcp"),
    put(dnsutil_test_res, UTD_DNS_13_1),
    [#sipdst{proto = tcp}] = url_to_dstlist(UTD_URL13_1, 1000, UTD_URL1_SIPS, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 13.2"),
    %% test with transport=tls parameter, not SIPS
    UTD_URL13_2 = sipurl:parse("sip:user@test.example.com:5012;transport=tls"),
    put(dnsutil_test_res, UTD_DNS_13_1),
    [#sipdst{proto = tls}] = url_to_dstlist(UTD_URL13_2, 1000, UTD_URL1_SIPS, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 13.3"),
    %% test with transport=udp parameter, not SIPS
    UTD_URL13_3 = sipurl:parse("sip:user@test.example.com:5012;transport=udp"),
    put(dnsutil_test_res, UTD_DNS_13_1),
    [#sipdst{proto = udp}] = url_to_dstlist(UTD_URL13_3, 1000, UTD_URL1_SIPS, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 13.4"),
    %% test with transport=udp parameter, but size > MTU, not SIPS
    UTD_URL13_4 = sipurl:parse("sip:user@test.example.com:5012;transport=udp"),
    put(dnsutil_test_res, UTD_DNS_13_1),
    [#sipdst{proto = tcp}] = url_to_dstlist(UTD_URL13_4, 12000, UTD_URL1_SIPS, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 13.5"),
    %% test with transport=bogus parameter, not SIPS
    UTD_URL13_5 = sipurl:parse("sip:user@test.example.com:5012;transport=bogus"),
    put(dnsutil_test_res, UTD_DNS_13_1),
    [#sipdst{proto = udp}] = url_to_dstlist(UTD_URL13_5, 1199, UTD_URL1_SIPS, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 15.1"),
    %% test without port, SIPS, and two IP addresses returned for the hostname
    UTD_URL15_1 = sipurl:parse("sips:user@test.example.com"),
    UTD_DNS_15_1 = {{siplookup, "test.example.com"},
			    [#sipdns_srv{proto = tcp,
					 host  = "incomingproxy.example.com",
					 port  = 5060},
			     #sipdns_srv{proto = udp,
					 host  = "incomingproxy.example.com",
					 port  = 5060},
			     #sipdns_srv{proto = tls,
					 host  = "incomingproxy.example.com",
					 port  = 5061}
			    ]},
    put(dnsutil_test_res, [UTD_DNS_15_1,
			   {{get_ip_port, "incomingproxy.example.com", 5061},
			    [#sipdns_hostport{family = inet6,
                                              addr   = "[2001:6b0:5:987::60]",
                                              port   = 5061
                                             },
			     #sipdns_hostport{family = inet,
                                              addr   = "192.0.2.2",
                                              port   = 5061
                                             }
			    ]}
			  ]),

    [#sipdst{proto     = tls6,
	     addr      = "[2001:6b0:5:987::60]",
	     port      = 5061,
	     uri       = UTD_URL15_1,
	     ssl_names = UTD_15_SSLNames
	    },
     #sipdst{proto     = tls,
	     addr      = "192.0.2.2",
	     port      = 5061,
	     uri       = UTD_URL15_1,
	     ssl_names = UTD_15_SSLNames
	    }
    ] = url_to_dstlist(UTD_URL15_1, 1199, UTD_URL15_1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 15.2"),
    %% verify that at least the domain name from the URL is a member of the SSLNames returned
    true = lists:member(UTD_URL15_1#sipurl.host, UTD_15_SSLNames),

    autotest:mark(?LINE, "url_to_dstlist/3 - 16"),
    %% test without port, not SIPS, will prefer best transport from DNS (first entry in UTD_DNS_15_1)
    UTD_URL16_1 = sipurl:parse("sip:user@test.example.com"),
    UTD_DNS_16_1 = {{get_ip_port, "incomingproxy.example.com", 5060},
		    [#sipdns_hostport{family = inet6,
				      addr   = "[2001:6b0:5:987::60]",
				      port   = 5060
				     }
		    ]},
    put(dnsutil_test_res, [UTD_DNS_15_1, UTD_DNS_16_1]),
    [#sipdst{proto     = tcp6,
	     addr      = "[2001:6b0:5:987::60]",
	     port      = 5060,
	     uri       = UTD_URL16_1
	    }
       ] = url_to_dstlist(UTD_URL16_1, 1199, UTD_URL16_1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 17"),
    %% test without port, not SIPS and transport=udp parameter
    UTD_URL17_1 = sipurl:parse("sip:user@test.example.com;transport=udp"),
    put(dnsutil_test_res, [UTD_DNS_15_1, UTD_DNS_16_1]),
    [#sipdst{proto     = udp6,
	     addr      = "[2001:6b0:5:987::60]",
	     port      = 5060,
	     uri       = UTD_URL17_1
	    }
       ] = url_to_dstlist(UTD_URL17_1, 1199, UTD_URL17_1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 18"),
    %% test with requested transport not found in DNS
    UTD_URL18_1 = sipurl:parse("sip:user@test.example.com;transport=tcp"),
    UTD_DNS_18_1 = {{siplookup, "test.example.com"},
			    [#sipdns_srv{proto = udp,
					 host  = "incomingproxy.example.com",
					 port  = 5060}
			    ]},
    put(dnsutil_test_res, [UTD_DNS_18_1]),
    [] = url_to_dstlist(UTD_URL18_1, 1199, UTD_URL18_1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 19"),
    %% test with NAPTR/SRV records pointing at a hostname that does not exist
    UTD_URL19_1 = sipurl:parse("sip:user@test.example.com"),
    UTD_DNS_19_1 = {{get_ip_port, "incomingproxy.example.com", 5060}, {error, nxdomain}},
    put(dnsutil_test_res, [UTD_DNS_15_1, UTD_DNS_19_1]),
    [] = url_to_dstlist(UTD_URL19_1, 1199, UTD_URL19_1, Testing),


    autotest:mark(?LINE, "url_to_dstlist/3 - 30"),
    %% test SIPS URI not upgradeable
    UTD_URL30_1 = sipurl:parse("sips:user@test.example.com"),
    UTD_URL30_2 = UTD_URL30_1#sipurl{proto = "test"},
    put(dnsutil_test_res, [UTD_DNS_15_1, UTD_DNS_16_1]),
    {'EXIT', {{error, _}, _}} = (catch url_to_dstlist(UTD_URL30_1, 1, UTD_URL30_2, Testing)),

    autotest:mark(?LINE, "url_to_dstlist/3 - 31"),
    %% test with non-nxdomain error when resolving NAPTR/SRV records
    UTD_URL31_1 = sipurl:parse("sip:test.example.com"),
    put(dnsutil_test_res, [{{siplookup, "test.example.com"}, {error, timeout}}]),
    {error, timeout} = url_to_dstlist(UTD_URL31_1, 1, UTD_URL31_1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 40.1"),
    %% test without NAPTR/SRV record but with a host address found
    UTD_URL40_1 = sipurl:parse("sip:user@test.example.com"),
    UTD_DNS40_1 = [{{siplookup, "test.example.com"}, {error, nxdomain}},
		   {{get_ip_port, "test.example.com", 5060},
		    [#sipdns_hostport{family = inet,
				      addr   = "192.0.2.40",
				      port   = 5060
				     }]},
		   {{get_ip_port, "test.example.com", 5061},
		    [#sipdns_hostport{family = inet,
				      addr   = "192.0.2.40",
				      port   = 5061
				     }]}
		   ],
    put(dnsutil_test_res, UTD_DNS40_1),

    [#sipdst{proto = udp,		%% udp since message size is small
	     addr = "192.0.2.40",
	     port = 5060,
	     uri  = UTD_URL1
	    }] = url_to_dstlist(UTD_URL40_1, 500, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 40.2"),
    %% test same with large message size
    put(dnsutil_test_res, UTD_DNS40_1),
    [#sipdst{proto = tcp,
	     addr = "192.0.2.40",
	     port = 5060,
	     uri  = UTD_URL1
	    }] = url_to_dstlist(UTD_URL40_1, 1400, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 41"),
    %% test with transport parameter set, TCP
    put(dnsutil_test_res, UTD_DNS40_1),
    [#sipdst{proto = tcp, port = 5060}]
	= url_to_dstlist(sipurl:parse("sip:test.example.com;transport=tcp"), 400, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 42"),
    %% test with transport parameter set, UDP
    put(dnsutil_test_res, UTD_DNS40_1),
    [#sipdst{proto = udp, port = 5060}]
	= url_to_dstlist(sipurl:parse("sip:test.example.com;transport=udp"), 14000, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 43"),
    %% test with transport parameter set, TLS
    put(dnsutil_test_res, UTD_DNS40_1),
    [#sipdst{proto = tls, port = 5061}]
	= url_to_dstlist(sipurl:parse("sip:test.example.com;transport=tls"), 300, UTD_URL1, Testing),

    autotest:mark(?LINE, "url_to_dstlist/3 - 44"),
    %% test with SIPS URL
    UTD_URL44_1 = sipurl:parse("sips:test.example.com"),
    put(dnsutil_test_res, UTD_DNS40_1),
    [#sipdst{proto = tls,
	     addr = "192.0.2.40",
	     port = 5061,
	     uri  = UTD_URL1_SIPS
	    }] = url_to_dstlist(UTD_URL44_1, 1400, UTD_URL1, Testing),


    %% test url_to_dstlist(URL, ApproxMsgSize)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "url_to_dstlist/2 - 1"),
    %% test with plain IP address but large message size, expect tcp destination
    UTD2_URL_1 = sipurl:parse("sip:192.0.2.50"),
    [#sipdst{proto = tcp,
	     addr  = "192.0.2.50",
	     port  = 5060,
	     uri   = UTD2_URL_1
	    }] = url_to_dstlist(UTD2_URL_1, 1500),


    %% test debugfriendly(Dst)
    %%--------------------------------------------------------------------
    autotest:mark(?LINE, "debugfriendly/1 - 1"),
    DebugF_1 = #sipdst{proto = tcp,
		       addr  = "test",
		       port  = 5000
		      },
    ["tcp:test:5000"] = debugfriendly(DebugF_1),

    autotest:mark(?LINE, "debugfriendly/2 - 1"),
    DebugF_2 = #sipdst{proto = udp6,
		       addr = "2001:6b0:5:987::1",
		       port = 6000
		      },
    ["tcp:test:5000 (sip:example.com)", "udp6:[2001:6b0:5:987::1]:6000"] =
	debugfriendly([DebugF_1#sipdst{uri = sipurl:parse("sip:example.com")},
		       DebugF_2]),

    ok.
