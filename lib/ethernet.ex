defmodule Ethernet do

  @moduledoc """

  Ethernet is an Actor that manages the configuration of an ethernet port.

  By default, Ethernet attempts to configure an ethernet port by using
  DHCP, reverting to AIPA / ipv4ll addressing configuration if that fails.
  It can also be used to statically configure a port upon request.

  Ethernet is implemented as a GenServer.

  # Support for AIPA / ipv4ll addressing

  If a DHCP IP cannot be obtained, Ethernet automatically configures an address
  on the 169.254.0.0/16 network.  Microsoft calls this AIPA, and the IETF
  calls it ipv4ll (ipv4 link local) addressing.

  Once a node has an ipv4ll address, it broadcasts a DHCP DISCOVER packet on a
  regular basis to see if a DHCP server re-appears.  The time of this
  rebroadcast is progressive (see ip4ll_dhcp_retry_time).   It also retries if
  it gets an SSDP notification from a client on another network.

  ## Configuration

  Configuration options may be specified in the application config file using
  the `:ethernet` key.

  ### Basic

  The `:interface` option specifies the interface name as specified by linux.
  *note:* This option may also be provided as an option to `start/1` or `start_link/1`
  as a Map

  The `:hostname` option may be used to specify the hostname to pass during
  a DHCP request. Default: "cell"
  *note:* This option may also be provided as an option to `start/1` or `start_link/1`
  as a Map

  ### Static config at compile time

  The `:ip` option may be used to specify a static ip address.

  The `:subnet` option is used to specify the subnet for the interface.
  Example: "255.255.0.0"

  The `:mask` option is used to specify the subnet mask. Example: 16

  The `:router` option used to specify the ip address of the router IP address.

  The `:dns` option is used to specify the ip address of the DNS server.
  Example: ["8.8.8.8", "4.4.4.4"]

  ### Persistence of static configuration

  Ethernet defines a Behaviour which allows the implementer the option to
  provide a mechenism to store the static configurations provided at runtime. An
  example using PersistentStorage can be found in `/examples`.

  To implement your own mechanism you must follow the defined behaviour and
  specify the module in the applications config file using the `:ethernet` key.

  ## Examples

  ### Configuration
  ```
  # Just specify the adapter and hostname so DHCP will be used on start
  config :ethernet, interface: "eth0", hostname: "radio"

  # Additionally, add options to configure static ip address on start
  config :ethernet, ip: "192.168.1.10", subnet: "255.255.0.0", mask: 16,
                    router: "192.168.1.1"

  # Specify a storage module
  config :ethernet, storage: EthernetPersistentStorage
  ```

  ### Usage
  ```
  # Using defaults
  Ethernet.start

  # Providing some config options
  Ethernet.start interface: eth2
  ```
  """

  use GenServer

  require Logger

  @interface    Application.get_env :ethernet, :interface, "eth0"
  @hostname     Application.get_env :ethernet, :hostname, "cell"
  @static_config Application.get_env :ethernet, :static_config, nil
  @storage_module Application.get_env :ethernet, :storage, nil

  @udhcpc_script_path   "/tmp/udhcpc.sh"

  @ssdp_ip_auto_uri     "sys/ip/auto"
  @ssdp_ip_static_uri   "sys/ip/static"

  @initial_state %{ interface: @interface, hostname: @hostname, status: "init",
                    dhcp_retries: 0, type: "ethernet", storage: @storage_module}

  @useful_dhcp_keys  [
    :status, :interface, :ip, :subnet, :mask, :timezone, :router,
    :timesvr, :dns, :hostname, :domain, :ipttl, :broadcast, :ntpsrv,
    :opt53, :lease, :dhcptype, :serverid, :message
  ]

  @public_keys [
    :interface, :hostname, :status, :dhcp_retries, :type, :ntpsrv, :ip,
    :subnet, :mask, :timezone, :router, :timesvr, :dns, :domain, :broadcast,
    :ipttl, :broadcast, :opt53, :lease, :dhcptype, :serverid, :message
  ]
  
  # TODO: make DefaultEthernet come from args, and handle multiple adapters
  # properly.

  @doc "Start genserver"
  def start(args \\ []) do
    name = DefaultEthernet
    GenServer.start __MODULE__, args, name: name
  end

  @doc "Start genserver with link to calling process"
  def start_link(args \\ []) do
    name = DefaultEthernet
    GenServer.start_link __MODULE__, args, name: name
  end

  @doc """
  Initializes the genserver (setting up the ethernet)
  """
  def init(args) do
    Logger.info "ethernet init with arguments: #{inspect args}" 
    {:ok, ref} = GenEvent.start_link # REVIEW iface as option?
    state = Dict.merge %{ notifier: ref }, args
    init_dhcp_subsystem
    state = update_and_announce(@initial_state, state)
    #Put information in services for client
    Logger.info "started ethernet agent in state #{inspect state}"
    os_cmd "/sbin/ip link set #{state.interface} up"
    {:ok, init_static_or_dynamic_ip(state)}
  end

  @doc """
  Called by SSDP module when UDP/HTTP verb comes in that is not NOTIFY or MSEARCH
  This feature is used to manage both manual and automatic IP configuration without
  a DHCP server, conforming to the 'static_ip' spec.
  """
  def ssdp_not_search_or_notify(packet, _ip \\ nil, _port \\ nil) do
    # Logger.debug "SSDP packet #{inspect packet}"
    # was {[raw_http_line], raw_params} = :erlang.list_to_binary(packet) |>
    #  String.split(["\n", "\r"], trim: true) |> Enum.split(1)
    {[raw_http_line], raw_params} = String.split(packet, ["\r\n", "\n"]) |> Enum.split(1)
    http_line = String.downcase(raw_http_line) |> String.strip
    {[http_verb, full_uri], _rest} = String.split(http_line) |> Enum.split(2)
    # SSDP is multicast, so make URI matches our device, ignoring otherwise
    valid_root_uri = String.downcase "http://#{:ssdp_root_device.get_ip_port}#{:ssdp_root_device.get_uri}"
    if String.starts_with?(full_uri, valid_root_uri) do
      [_, rel_uri] = String.split full_uri, valid_root_uri
      #Logger.debug "SSDP #{http_line} received"
      mapped_params = Enum.map raw_params, fn(x) ->
        case String.split(x, ":") do
          [k, v] -> {String.to_atom(String.downcase(k)), String.strip(v)}
          _ -> nil
        end
      end
      filtered_params = Enum.reject mapped_params, &(&1 == nil)
      #Logger.debug "Parsed into params: #{inspect filtered_params}"
      GenServer.cast(DefaultEthernet, {:ssdp_http, {eb2a(http_verb), rel_uri, filtered_params}})
    else
      #Logger.debug "SSDP #{http_line} received, but not for me"
      nil
    end
  end

  ############################ http ssdp handlers ###########################
  # configure manual static IP
  # REVIEW: currently ignores DNS (resolver) settings, not important right now
  # TODO URGENT: hadndle multiple puts of this

  @doc false
  def handle_cast({:ssdp_http, {:put, @ssdp_ip_static_uri, params}}, state) do
    Logger.info "request to put static IP with params #{inspect params}"
    ifcfg = [ip: params[:"x-ip"], mask: params[:"x-subnet"], router: params[:"x-router"],
             status: "static", dhcp_retries: 0]
    if ((ifcfg[:ip] != state.ip) or (ifcfg[:mask] != state.mask) or (ifcfg[:router] != state.router)) do
      state = configure_interface state, ifcfg
      if state[:storage], do: state.storage.put(ifcfg)
    end
    {:noreply, state}
  end

  # configure automatic static ip
  def handle_cast({:ssdp_http, {:put, @ssdp_ip_auto_uri, params}}, state) do
    Logger.debug "NOT YET IMPLEMENTED - Asked to configure autohop IP with params #{inspect params}"
    {:noreply, state}
  end

  # deconfigure manual static IP
  def handle_cast({:ssdp_http, {:delete, @ssdp_ip_static_uri, _params}}, state) do
    Logger.info "Deconfiguring Static IP"
    if state[:storage], do: state.storage.delete
    {:noreply, configure_with_dynamic_ip(state)}
  end

  # deconfigure automatic static ip
  def handle_cast({:ssdp_http, {:delete, @ssdp_ip_auto_uri, _params}}, state) do
    Logger.info "Deconfiguring Automatic Hopping IP"
    {:noreply, configure_with_dynamic_ip(state)}
  end

  # try renewing dhcp lease upon expiration unless we've been configured
  # as a static ip in the meantime
  def handle_info(:dhcp_lease_expired, state) do
    case state.status do
      "static" -> {:noreply, state}
      _ -> {:noreply, configure_with_dynamic_ip(state)}
    end
  end

  # called periodically to try to see if a dhcp server came back online
  def handle_info(:ip4ll_dhcp_retry, state) do
    params = make_raw_dhcp_request(state)
    case params[:status] do
      "bound" -> configure_dhcp(state, params)
      "renew" -> configure_dhcp(state, params)
      _ ->
        state = schedule_ip4ll_dhcp_retry(state)
    end
    {:noreply, state}
  end

  defp schedule_ip4ll_dhcp_retry(state) do
    interval = dhcp_retry_interval(state.dhcp_retries)
    retry =  state.dhcp_retries + 1
    #Logger.debug "scheduling dhcp retry ##{retry} for #{interval} ms"
    :erlang.send_after interval, Kernel.self, :ip4ll_dhcp_retry
    update_and_announce state, dhcp_retries: retry
  end

  # retry after 10 seconds for the first 10 retries, then 1 min
  defp dhcp_retry_interval(tries) when tries >= 10, do: 60000
  defp dhcp_retry_interval(_tries), do: 10000

  # update changes and announce
  defp update_and_announce(state, changes) do
    public_changes = Dict.take changes, @public_keys
    if Enum.any?(public_changes) and state[:on_change] do
      state.on_change.(public_changes)
    end
    Dict.merge(state, changes)
  end

  # a few assorted helpers to delegate to native erlang

  defp el2b(l), do: :erlang.list_to_binary(l)
  defp eb2l(b), do: :erlang.binary_to_list(b)
  defp eb2a(b), do: String.to_atom(b)
  defp os_cmd(cmd) do
    ret = :os.cmd(eb2l(cmd)) |> el2b
    Logger.debug "#{__MODULE__} cmd: #{inspect cmd} returned: #{inspect ret}"
    ret
  end

  # write out a script that udhcpc can use in a client mode to do dhcp requests
  defp init_dhcp_subsystem do
    udhcpc_script="#!/bin/sh\necho [\necho status=\\'$1\\'\nset\necho ]\n"
    File.write @udhcpc_script_path, udhcpc_script
    File.chmod @udhcpc_script_path, 0777
  end

  # If we already have a static configuration in flash, honor that,
  # otherwise do dhcp with fallback to ip4ll if dhcp fails
  defp init_static_or_dynamic_ip(state) do
    Logger.debug "eth: reading static configuration"
    case state[:storage] do
      nil -> configure_dynamic_or_static_ip(state)
      fun -> case fun.get do
        nil ->
          configure_dynamic_or_static_ip(state)
        config ->
          Logger.info "eth: found persistent static config"
          configure_with_static_ip(state, config)
      end
    end
  end

  # Check if we have a static config defined by the config file. If so then use
  # it, otherwise fallback to dhcp (and eventually ip4ll)
  defp configure_dynamic_or_static_ip(state) do
    case @static_config do
      nil ->
        Logger.info "eth: no static ip configuration found, trying dynamic config"
        configure_with_dynamic_ip(state)
      config ->
        Logger.info "eth: Static configuration found in config.exs"
        configure_with_static_ip(state, config)
    end
  end

  # setup the interface to ahve a static ip address
  defp configure_with_static_ip(state, params) do # -> new_state
    params = Dict.merge(%{status: "static"}, params)
    Logger.info "configuring static ip as #{inspect params}"
    state = update_and_announce(state, params)
    configure_interface(state, params)
  end

  # setup the interface to have a dynamic (dhcp or ip4ll) address
  defp configure_with_dynamic_ip(state) do # -> new_state
    Logger.debug "starting dynamic ip allocation"
    state = update_and_announce state, status: "request"
    params = make_raw_dhcp_request(state)
    case params[:status] do
      "bound" ->
        configure_dhcp(state, params)
      "renew" ->
        configure_dhcp(state, params)
      _ ->
        configure_ip4ll(state)
    end
  end

  defp configure_dhcp(state, params) do
    state = %{state | dhcp_retries: 0 }
    if Dict.has_key?(params, :lease) do
      lease = :erlang.binary_to_integer(params[:lease])
      :erlang.send_after lease*1000, Kernel.self, :dhcp_lease_expired
    end
    configure_interface(state, params)
  end

  # setup an ipv4ll address (autoconfigured address) with timer
  defp configure_ip4ll(state) do
    params = ip4ll_params(state)
    schedule_ip4ll_dhcp_retry(state)
    configure_interface(state, params)
  end

  defp ip4ll_params(state) do
    [ interface: state.interface, ip: calculate_ip4ll_ip_from_state(state),
    mask: "16", subnet: "255.255.0.0",  status: "ip4ll", dhcp_retries: 0 ]
  end

  defp calculate_ip4ll_ip_from_state(state) do
    maddr = File.read! "/sys/class/net/#{state.interface}/address"
    seed = :crypto.hash(:md5, maddr)
    <<x, y, _rest :: bytes>> = seed
    if (x==255 and y==255), do: y = y-1
    if (x==0 and y==0), do: y = y+1
    "169.254.#{x}.#{y}"
  end

  # given params, do a configuration of the interface and announce
  defp configure_interface(state, params) do
    Logger.info "setting up interface #{state.interface} with: #{inspect params}"
    if params[:ip] && params[:mask] do
      os_cmd "ip addr flush dev #{state.interface}"
      os_cmd "ip addr add #{params[:ip]}/#{params[:mask]} dev #{state.interface}"
      if params[:router] do
        os_cmd "ip route add default via #{params[:router]} dev #{state.interface}"
      end
    end
    update_and_announce(state, params)
  end

  ################################# utility functions ##########################

  # given "foobar='yahoo'", returns {:foobar, "yahoo"} to help parse result of
  # udhcpc into something useful for us
  defp cleanup_kv([_,kqval]) do
    [key, qval] = String.split(kqval, "=")
    [_, val] = Regex.run(~r/'(.+)'/s, qval) # remove single quotes
    {eb2a(key), val}
  end

    # call udhcpc in non-daemon mode, walking through resulting responses
  # to select the last (most relelvant) response, then convert it to
  # a hash containing only relelvant keys.
  # state is used to determine hostname and interface id
  defp make_raw_dhcp_request(state) do
    Logger.info "making dhcp req from '#{state.hostname}' on #{state.interface}"
    env = os_cmd "udhcpc -n -q -f -s #{@udhcpc_script_path} --interface=#{state.interface} -x hostname:#{state.hostname}"
    #Logger.debug "Made DHCP request, got: #{inspect env}"
    [_, [last_response]] = Regex.scan ~r/\[.*\]/sr, env
    Enum.map(Regex.scan(~r/(\w+='.+')\n/r, last_response), &cleanup_kv/1)
    |> Enum.filter(fn({k,_v}) -> Enum.member?(@useful_dhcp_keys, k) end)
  end

end
