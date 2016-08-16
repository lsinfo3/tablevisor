%%%-------------------------------------------------------------------
%%% @author Stefan Herrnleben
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Mai 2015 14:20
%%%-------------------------------------------------------------------
-module(tablevisor_ctrl4).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("pkt/include/pkt.hrl").
-include_lib("pkt2/include/pkt_lldp.hrl").

-compile([{parse_transform, lager_transform}]).

%% API
-export([
  start/1,
  send/2,
  send/3,
  message/1,
  tablevisor_switches/0,
  tablevisor_tables/0,
  tablevisor_switch_get/2,
  tablevisor_switch_get_outport/2,
  tablevisor_switch_get_gototable/2,
  tablevisor_wait_for_switches/0,
  tablevisor_topology_discovery/0
]).


%% @doc Start the server.
start(Port) ->
  lager:start(),
  spawn_link(
    fun() ->
      Opts = [binary, {packet, raw}, {active, once}, {reuseaddr, true}],
      {ok, LSocket} = gen_tcp:listen(Port, Opts),
      accept(LSocket)
    end).

accept(LSocket) ->
  {ok, Socket} = gen_tcp:accept(LSocket),
  Pid = spawn_link(
    fun() ->
      inet:setopts(Socket, [{active, once}]),
      handle_socket(Socket, [], <<>>)
    end),
  Pid ! {new},
  ok = gen_tcp:controlling_process(Socket, Pid),
  accept(LSocket).

%% The echo client process.
handle_socket(Socket, Waiters, Data1) ->
  ok = inet:setopts(Socket, [{active, once}]),
  receive
    {tcp, Socket, Data} ->
      Data2 = <<Data1/binary, Data/binary>>,
      <<_Version:8, _TypeInt:8, Length:16, _XID:32, _Binary2/bytes>> = Data2,
      % lager:info("Version ~p, TypeInt ~p, Length ~p, Xid ~p, calculated Length ~p",[Version, TypeInt, Length, XID, byte_size(Data)]),
      case Length of
        N when N > byte_size(Data2) ->
          handle_socket(Socket, Waiters, Data2);
        N when N < byte_size(Data2) ->
          lager:error("Multiple OpenFlow messages in one TCP bytestream");
        _ ->
          true
      end,
      {ok, Parser} = ofp_parser:new(4),
      lager:debug("InputData from ~p: ~p", [Socket, Data]),
      Parsed = ofp_parser:parse(Parser, Data2),
      case Parsed of
        {ok, _, _} ->
          true;
        {error, Exception} ->
          lager:error("Error while parsing ~p because ~p", [Data, Exception]),
          handle_socket(Socket, Waiters, <<>>)
      end,
      {ok, _NewParser, Messages} = Parsed,
      lager:debug("Received messages from socket ~p", [Messages]),
      FilteredWaiters = filter_waiters(Waiters),
      lists:foreach(
        fun(Message) ->
          Xid = Message#ofp_message.xid,
          spawn_link(
            fun() ->
              send_to_waiters(Socket, Message, Xid, FilteredWaiters),
              handle_input(Socket, Message)
            end)
        end, Messages),
      handle_socket(Socket, FilteredWaiters, <<>>);
  % close tcp socket by client (rb)
    {tcp_closed, Socket} ->
      tablevisor_switch_remove(Socket),
      lager:error("Client ~p disconnected.", [Socket]);
  % say hello, negotiate ofp version and get datapath id after connect
    {new} ->
      do_send(Socket, hello()),
      ListenerPid = self(),
      spawn_link(
        fun() ->
          send_features_request(Socket, ListenerPid)
        end),
      handle_socket(Socket, Waiters, <<>>);
    {add_waiter, Waiter} ->
      handle_socket(Socket, [Waiter | Waiters], <<>>);
    Other ->
      lager:error("Received unknown signal ~p", [Other]),
      handle_socket(Socket, Waiters, <<>>)
  end.

filter_waiters(Waiters) ->
  [Waiter || Waiter <- Waiters, is_process_alive(Waiter)].

send_features_request(Socket, Pid) ->
  timer:sleep(5000),
  Message = features_request(),
  Xid = Message#ofp_message.xid,
  lager:info("Send features request to ~p, xid ~p, message ~p", [Socket, Xid, Message]),
  tablevisor_us4:tablevisor_log("~sSend ~sfeatures-request~s to socket ~p", [tablevisor_us4:tvlc(green), tablevisor_us4:tvlc(green, b), tablevisor_us4:tvlc(green), Socket]),
  Pid ! {add_waiter, self()},
  do_send(Socket, Message),
  receive
    {msg, Reply, Xid} ->
      lager:info("Received features reply from ~p, message ~p", [Socket, Reply]),
      tablevisor_us4:tablevisor_log("~sReceived ~sfeatures-reply~s from socket ~p", [tablevisor_us4:tvlc(green), tablevisor_us4:tvlc(green, b), tablevisor_us4:tvlc(green), Socket]),
      Body = Reply#ofp_message.body,
      DataPathMac = Body#ofp_features_reply.datapath_mac,
      DataPathId = binary_to_int(DataPathMac),
      tablevisor_us4:tablevisor_log("~sReceived ~sfeatures-reply~s from socket ~p (dpid ~.16B)", [tablevisor_us4:tvlc(green), tablevisor_us4:tvlc(green, b), tablevisor_us4:tvlc(green), Socket, DataPathId]),
      %lager:info("DataPathId ~p", [DataPathId]),
      {ok, TableId} = tablevisor_switch_connect(DataPathId, Socket, Pid),
      lager:info("Registered new Switch DataPath-ID ~.16B, Socket ~p, Pid ~p, Table-Id ~p", [DataPathId, Socket, Pid, TableId]),
      tablevisor_us4:tablevisor_log("~sRegistered switch with dpid ~.16B representing table ~s~p", [tablevisor_us4:tvlc(green), DataPathId, tablevisor_us4:tvlc(green, b), TableId]),
      % set flow mod to enable process table different 0
      tablevisor_us4:tablevisor_init_connection(TableId),
      true
  after 2000 ->
    lager:error("Error while waiting for features reply from ~p, xid ~p", [Socket, Xid]),
    false
  end.

handle_input(Socket, Message) ->
  Xid = Message#ofp_message.xid,
  case Message of
    #ofp_message{body = #ofp_error_msg{type = hello_failed, code = incompatible}} ->
      lager:error("Received hello failed from ~p: ~p", [Socket, Message]),
      gen_tcp:close(Socket);
    #ofp_message{body = #ofp_error_msg{}} ->
      lager:info("Received error message from ~p: ~p", [Socket, Message]),
      tablevisor_us4:ofp_error_msg(Message);
    #ofp_message{body = #ofp_echo_request{}} ->
      lager:debug("Received echo request from ~p: ~p", [Socket, Message]),
      do_send(Socket, message(echo_reply(), Xid));
    #ofp_message{body = #ofp_hello{}} ->
      lager:info("Received hello message from ~p: ~p", [Socket, Message]);
    #ofp_message{body = #ofp_port_stats_reply{}} ->
      lager:debug("Received port stats reply from ~p: ~p", [Socket, Message]);
    #ofp_message{body = #ofp_features_reply{datapath_mac = _DataPathMac}} ->
      lager:debug("Received features reply message from ~p: ~p", [Socket, Message]);
    #ofp_message{body = #ofp_packet_in{}} ->
      lager:debug("Received packet in from ~p: ~p", [Socket, Message]),
      case tablevisor_switch_get(Socket, tableid) of
        false ->
          false;
        TableId ->
          tablevisor_us4:ofp_packet_in(TableId, Message)
      end;
    #ofp_message{} ->
      lager:info("Received message from ~p: ~p", [Socket, Message])
    %_ ->
    %  lager:error("Unknown message: ~p", [Message])
  end.

send_to_waiters(_Socket, _Message, _Xid, []) ->
  true;
send_to_waiters(Socket, Message, Xid, [Waiter | Waiters]) ->
  lager:debug("Send to waiter ~p, xid ~p, message ~p", [Waiter, Xid, Message]),
  Waiter ! {msg, Message, Xid},
  send_to_waiters(Socket, Message, Xid, Waiters).


%%%-----------------------------------------------------------------------------
%%% Helpers
%%%-----------------------------------------------------------------------------

message(Body) ->
  Xid = get_xid(),
  message(Body, Xid).

message(Body, Xid) ->
  #ofp_message{version = 4,
    xid = Xid,
    body = Body}.

get_xid() ->
  random:uniform(1 bsl 32 - 1).

binary_to_int(Bin) ->
  Size = size(Bin),
  <<Int:Size/integer-unit:8>> = Bin,
  Int.

%binary_to_hex(Bin) ->
%  binary_to_hex(Bin, "").

%binary_to_hex(<<>>, Result) ->
%  Result;
%binary_to_hex(<<B:8, Rest/bits>>, Result) ->
%  Hex = erlang:integer_to_list(B, 16),
%  NewResult = Result ++ ":" ++ Hex,
%  binary_to_hex(Rest, NewResult).

%%%-----------------------------------------------------------------------------
%%% ETS Helper
%%%-----------------------------------------------------------------------------

tablevisor_switch_remove(_Socket) ->
  true.

tablevisor_switch_connect(DataPathId, Socket, Pid) ->
  SwitchList = tablevisor_switches(),
  SearchByDpId =
    fun(TableId, Config) ->
      {dpid, DpId} = lists:keyfind(dpid, 1, Config),
      case DpId of
        DataPathId ->
          tablevisor_switch_set(TableId, socket, Socket),
          tablevisor_switch_set(TableId, pid, Pid),
          ets:insert(tablevisor_socket, {Socket, TableId});
        _ ->
          false
      end
    end,
  [SearchByDpId(TableId, Config) || {TableId, Config} <- SwitchList],
  TableId2 = tablevisor_switch_get(Socket, tableid),
  {ok, TableId2}.

tablevisor_switch_get(TableId, Key) when is_integer(TableId) ->
  try
    Config = ets:lookup_element(tablevisor_switch, TableId, 2),
    % lager:error("Key ~p, Config ~p",[Key, Config]),
    {Key, Value} = lists:keyfind(Key, 1, Config),
    Value
  catch
    error:badarg ->
      lager:error("No Switch with TableId ~p registered", [TableId]),
      false
  end;
tablevisor_switch_get(Socket, Key) ->
  try
    TableId = ets:lookup_element(tablevisor_socket, Socket, 2),
    tablevisor_switch_get(TableId, Key)
  catch
    error:badarg ->
      lager:error("No Switch with Socket ~p registered", [Socket]),
      false
  end.

tablevisor_switch_set(TableId, Key, NewValue) ->
  try
    ReplaceConfig =
      fun(OldKey, OldValue) ->
        case OldKey of
          Key ->
            {OldKey, NewValue};
          _ ->
            {OldKey, OldValue}
        end
      end,
    Config = ets:lookup_element(tablevisor_switch, TableId, 2),
    NewConfig = [ReplaceConfig(Key2, Value2) || {Key2, Value2} <- Config],
    ets:insert(tablevisor_switch, {TableId, NewConfig})
  catch
    error:badarg ->
      lager:error("Error in ttpsim_switch_set", [TableId]),
      false
  end.

-spec tablevisor_switches() -> true.
tablevisor_switches() ->
  ets:tab2list(tablevisor_switch).

-spec tablevisor_tables() -> true.
tablevisor_tables() ->
  Switches = tablevisor_switches(),
  [TableId || {TableId, _} <- Switches].

tablevisor_switch_get_outport(SrcTableId, DstTableId) ->
  OutportMap = tablevisor_switch_get(SrcTableId, outportmap),
  Result = lists:keyfind(DstTableId, 1, OutportMap),
  case Result of
    {DstTableId, Outport} ->
      Outport;
    false ->
      false
  end.

tablevisor_switch_get_gototable(SrcTableId, OutPort) ->
  OutportMap = tablevisor_switch_get(SrcTableId, outportmap),
  DstTables = [D || {D, OutPort2} <- OutportMap, OutPort2 == OutPort],
  case DstTables == [] of
    true ->
      false;
    false ->
      [DstTableId | _] = DstTables,
      DstTableId
  end.

tablevisor_wait_for_switches() ->
  Switches = tablevisor_tables(),
  tablevisor_wait_for_switches(Switches).
tablevisor_wait_for_switches([TableId | Tables]) ->
  %lager:info("Waiting for switches ~p, currently ~p.", [[TableId | Tables], TableId]),
  Socket = tablevisor_switch_get(TableId, socket),
  case Socket of
    false ->
      timer:sleep(1000),
      tablevisor_wait_for_switches([TableId | Tables]);
    _ ->
      %lager:info("Switch ~p removed from waiting queue.", [TableId]),
      tablevisor_wait_for_switches(Tables)
  end;
tablevisor_wait_for_switches([]) ->
  true.

%%%-----------------------------------------------------------------------------
%%% TableVisor Topology Discovery via LLDP
%%%-----------------------------------------------------------------------------

tablevisor_topology_discovery() ->
  Timeout = 2, % Timeout in seconds
  Switches = tablevisor_tables(),
  tablevisor_toplogy_discovery_flowmod(Switches, Timeout),
  ReceiverPidList = tablevisor_topology_discovery_listener(Switches),
  tablevisor_topology_discovery_lldp(Switches),
  timer:sleep(Timeout * 1000),
  ConnectionList = tablevisor_topology_discovery_fetcher(ReceiverPidList),
  lager:debug("Discovered connections: ~p", [ConnectionList]),
  Graph = tablevisor_toplogy_discovery_build_digraph(ConnectionList),
  Graph.

tablevisor_toplogy_discovery_flowmod([TableId | Tables], FlowModTimeout) ->
  % get socket for current table (switch)
  Socket = tablevisor_switch_get(TableId, socket),
  % generate Flow mod to push all LLDP packets to controller
  FlowMod = message(#ofp_flow_mod{
    table_id = 0,
    command = add,
    hard_timeout = FlowModTimeout + 1,
    idle_timeout = FlowModTimeout + 1,
    priority = 255,
    flags = [],
    match = #ofp_match{fields = [#ofp_field{name = eth_type, value = <<16#88cc:16>>}]},
    instructions = [#ofp_instruction_apply_actions{actions = [#ofp_action_output{port = controller}]}]
  }),
  % send packet to switch
  do_send(Socket, FlowMod),
  % continue with topology discovery flowmods with other tables
  tablevisor_toplogy_discovery_flowmod(Tables, FlowModTimeout);
tablevisor_toplogy_discovery_flowmod([], _FlowModTimeout) ->
  true.

tablevisor_topology_discovery_listener(Tables) ->
  tablevisor_topology_discovery_listener(Tables, []).
tablevisor_topology_discovery_listener([TableId | Tables], ReceiverPidList) ->
  ReceiverPid = spawn(
    fun() ->
      Socket = tablevisor_switch_get(TableId, socket),
      Pid = tablevisor_switch_get(Socket, pid),
      Pid ! {add_waiter, self()},
      tablevisor_topology_discovery_receiver(TableId)
    end),
  % continue with topology discovery listeners with other tables
  tablevisor_topology_discovery_listener(Tables, ReceiverPidList ++ [ReceiverPid]);
tablevisor_topology_discovery_listener([], ReceiverPidList) ->
  ReceiverPidList.

tablevisor_topology_discovery_receiver(TableId) ->
  tablevisor_topology_discovery_receiver(TableId, []).
tablevisor_topology_discovery_receiver(TableId, ConnectionList) ->
  receive
    {msg, Reply, _Xid} ->
      case Reply of
        #ofp_message{body = #ofp_packet_in{}} ->
          Pkt = pkt2:decapsulate(Reply#ofp_message.body#ofp_packet_in.data),
          L3Pdu = lists:nth(2, Pkt),
          case L3Pdu of
            #lldp{} ->
              [IngressPort | _] = [binary_to_int(F#ofp_field.value) || F <- Reply#ofp_message.body#ofp_packet_in.match#ofp_match.fields, is_record(F, ofp_field) andalso F#ofp_field.name =:= in_port],
              [SrcSwitchId | _] = [binary_to_int(F#chassis_id.value) || F <- L3Pdu#lldp.pdus, is_record(F, chassis_id)],
              [EgressPort | _] = [binary_to_int(F#port_id.value) || F <- L3Pdu#lldp.pdus, is_record(F, port_id)],
              lager:debug("LLDP Packet in Switch ~p in Port ~p from Switch ~p from Port ~p", [TableId, IngressPort, SrcSwitchId, EgressPort]),
              tablevisor_topology_discovery_receiver(TableId, ConnectionList ++ [{{SrcSwitchId, EgressPort}, {TableId, IngressPort}}]);
            _ ->
              tablevisor_topology_discovery_receiver(TableId, ConnectionList)
          end;
        _ ->
          tablevisor_topology_discovery_receiver(TableId, ConnectionList)
      end;
    {get_replies, ServerPid} ->
      ServerPid ! {connections, ConnectionList}
  end.

tablevisor_topology_discovery_lldp([TableId | Tables]) ->
  % get socket for current table (switch)
  Socket = tablevisor_switch_get(TableId, socket),
  % build request for single switch
  Request = message(#ofp_port_stats_request{port_no = any}),
  % send request and receive reply
  {reply, Reply} = send(TableId, Request, 2000),
  % anonymous function for sending LLDP packets
  LLDPSender =
    fun(OutputPortNo) ->
      % build ethernet header for LLDP packet
      EtherPktBin = pkt_ether:codec(#ether{dhost = <<16#01, 16#80, 16#c2, 16#00, 16#00, 16#0e>>, shost = <<0, 0, 0, 0, 0, 0>>, type = 16#88cc}),
      % build LLDP packet
      LldpPktBin = pkt_lldp:codec(#lldp{pdus = [
        #chassis_id{value = <<TableId>>},
        #port_id{value = <<OutputPortNo>>},
        #ttl{value = 5}
      ]}),
      % build OpenFlow packet out message with LLDP packet
      OFPktOut = message(#ofp_packet_out{buffer_id = no_buffer, actions = [#ofp_action_output{port = OutputPortNo}], data = <<EtherPktBin/binary, LldpPktBin/binary>>}),
      % send OpenFlow packet out message to switch
      do_send(Socket, OFPktOut)
    end,
  % iterate through each port
  [
    if
      is_integer(PortStats#ofp_port_stats.port_no) ->
        LLDPSender(PortStats#ofp_port_stats.port_no);
      true ->
        true
    end
    || PortStats <- Reply#ofp_port_stats_reply.body
  ],
  % continue with topology discovery with other tables
  tablevisor_topology_discovery_lldp(Tables);
tablevisor_topology_discovery_lldp([]) ->
  true.

tablevisor_topology_discovery_fetcher(ReceiverPidList) ->
  tablevisor_topology_discovery_fetcher(ReceiverPidList, []).
tablevisor_topology_discovery_fetcher([ReceiverPid | ReceiverPidList], ConnectionList) ->
  ReceiverPid ! {get_replies, self()},
  receive
    {connections, NewConnections} ->
      true
  after 10000 ->
    NewConnections = []
  end,
  tablevisor_topology_discovery_fetcher(ReceiverPidList, ConnectionList ++ NewConnections);
tablevisor_topology_discovery_fetcher([], ConnectionList) ->
  ConnectionList.

tablevisor_toplogy_discovery_build_digraph(ConnectionList) ->
  G = digraph:new(),
  tablevisor_toplogy_discovery_build_digraph(G, ConnectionList).
tablevisor_toplogy_discovery_build_digraph(G, [Connection | ConnectionList]) ->
  {{V1, P1}, {V2, P2}} = Connection,
  digraph:add_vertex(G, V1),
  digraph:add_vertex(G, V2),
  digraph:add_edge(G, V1, V2, {P1, P2}),
  tablevisor_toplogy_discovery_build_digraph(G, ConnectionList);
tablevisor_toplogy_discovery_build_digraph(G, []) ->
  VList = digraph:vertices(G),
  lager:debug("Vertices: ~p", [VList]),
  [
    lager:debug("Connections from ~p to ~p", [V, digraph:out_neighbours(G, V)])
    || V <- VList
  ],
  G.

%%%-----------------------------------------------------------------------------
%%% Sender
%%%-----------------------------------------------------------------------------

send(TableId, Message) when is_integer(TableId) ->
  Socket = tablevisor_switch_get(TableId, socket),
  send(Socket, Message);
send(Socket, Message) ->
  %lager:info("Send (cast) to ~p, message ~p", [Socket, Message]),
  do_send(Socket, Message),
  {noreply, ok}.

send(TableId, Message, Timeout) when is_integer(TableId) ->
  Socket = tablevisor_switch_get(TableId, socket),
  send(Socket, Message, Timeout);
send(Socket, Message, Timeout) ->
  Pid = tablevisor_switch_get(Socket, pid),
  Pid ! {add_waiter, self()},
  Xid = Message#ofp_message.xid,
  lager:debug("Send (call) to ~p, xid ~p, message ~p", [Socket, Xid, Message]),
  do_send(Socket, Message),
  receive
    {msg, Reply, Xid} ->
      ReplyBody = Reply#ofp_message.body,
      lager:debug("Received from ~p, xid ~p, message ~p", [Socket, Xid, Reply]),
      {reply, ReplyBody}
  after Timeout ->
    lager:error("Error while waiting for reply from ~p, xid ~p", [Socket, Xid]),
    {error, timeout}
  end.

do_send(Socket, Message) when is_tuple(Message) ->
  case of_protocol:encode(Message) of
    {ok, EncodedMessage} ->
      do_send(Socket, EncodedMessage);
    _Error ->
      lager:error("Error in encode of: ~p", [Message])
  end;
do_send(Socket, Message) when is_binary(Message) ->
  gen_tcp:send(Socket, Message).


%%%-----------------------------------------------------------------------------
%%% Message generators
%%%-----------------------------------------------------------------------------

hello() ->
  message(#ofp_hello{}).

features_request() ->
  message(#ofp_features_request{}).

echo_reply() ->
  echo_reply(<<>>).
echo_reply(Data) ->
  #ofp_echo_reply{data = Data}.


