#
# This script will download data from the three load sensors on the prop test
# rig and output them to a CSV file. It will also interface the multi hole
# probe. And also note the RPM coming from VESC with Id 101, 102, 103, 104, 105
#
# To get the CANable USB adapter to connect to CAN on 250 kbps (for VESC and
# multi hole probe) you need to issue the following commands
#
# $ sudo ip link set can0 down
# $ sudo slcand -o -c -s5 /dev/ttyACM0 can0
# $ sudo ip link set can0 up
#
# Then to see if you are online, look at the traffic by issuing (press Ctrl+C
# to quit)
#
# $ candump can0
#
# To connect to the load cell amplifiers, you need to connect to a local
# network on the same subnet as the modbus Ethernet gateway. This could be done
# in the control panel in Linux using eg.
#
# IP address 192.168.0.238
# Netmask 255.255.255.0
#
# To see if you are connected, run
#
# $ ping 192.168.0.329
# $ modbus read -s 1 192.168.0.239 %MW0 2
#
#
# Run the script with
#
# $ cd
# $ cd proptest
# $ elixir proptest_logger.exs
#
# Press Ctrl+C twice to exit the logger.
#
# For every run, a new .csv file is generated in the proptest folder.
#
# ! Pro tip: type `nautilus &` to open the file explorer
#
# We are logging ERPM for the VESCs. The ERPM must be divided by half the
# number of poles on the motor itself to get the actual RPM on the shaft. For
# both the Hacker and KDE motors, this number is (28 / 2). So eg. 14000 ERPM
# means 1000 RPM on the shaft. The maximum speed of the motors is around 5000
# RPM [70_000 ERPM].
#
# The Modbus TCP gateway is set up with:
# - Address 192.168.0.239
# - Port 502
# - Mode RTU to TCP
# - Baud rate 9600
#
#
# The load cell amplifiers are set up with (manual in teams under components)
# - F2.CAL/Data/range 500
# - F2.CAL/Data/Sensitivity <according to calibration sheet>
# - F1.SEt/SerP/Ad 1/2/3 for X/Y/Z respectively
#
# Other settings default values

Mix.install(
  [
    {:modbus, "~> 0.4.0"},
    # {:cannes, "~> 0.0.5"},
    {:cannes, github: "tallakt/cannes", branch: "master"}
  ],
  config: [porcelain: [driver: Porcelain.Driver.Basic]]
)

# This agent holds the data from the probe so it can be accessed asyncronically
defmodule ProbeAndVESCAgent do
  use Agent

  @vesc_status_1 9
  @vesc_status_4 16

  def start_link() do
    initial_value = %{
      p1: 0.0,
      p2: 0.0,
      p3: 0.0,
      p4: 0.0,
      p5: 0.0,
      p6: 0.0,
      p7: 0.0,
      p8: 0.0,
      temperature: 0.0,
      erpm_101: -99,
      erpm_102: -99,
      erpm_103: -99,
      erpm_104: -99,
      current_in_101: -99,
      current_in_102: -99,
      current_in_103: -99,
      current_in_104: -99,
      motor_current_101: -99,
      motor_current_102: -99,
      motor_current_103: -99,
      motor_current_104: -99
    }

    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def get() do
    Agent.get(__MODULE__, & &1)
  end

  def handle_can_packet(packet) do
    Agent.update(__MODULE__, fn state -> handle_can_packet_helper(packet, state) end)
  end

  defp evoscann_raw_to_mbar(x) do
    <<tmp::signed-16>> = <<x - 32768::integer-16>>
    tmp / 320.0
  end

  defp handle_can_mhp_helper(packet, state) do
    case packet.data do
      <<0, p1::big-16, p2::big-16, p3::big-16, _::binary>> ->
        %{
          state
          | p1: evoscann_raw_to_mbar(p1),
            p2: evoscann_raw_to_mbar(p2),
            p3: evoscann_raw_to_mbar(p3)
        }

      <<1, p4::big-16, p5::big-16, p6::big-16, t::signed>> ->
        %{
          state
          | p4: evoscann_raw_to_mbar(p4),
            p5: evoscann_raw_to_mbar(p5),
            p6: evoscann_raw_to_mbar(p6),
            temperature: t
        }

      <<2, p7::big-16, p8::big-16, _::binary>> ->
        %{state | p7: evoscann_raw_to_mbar(p7), p8: evoscann_raw_to_mbar(p8)}

      _ ->
        state
    end
  end

  defp handle_can_vesc_helper_status_1(packet, vesc_id, state)
       when vesc_id in [101, 102, 103, 104] do
    case packet.data do
      <<erpm::integer-big-32-signed, motor_current::integer-big-16-signed, _::binary>> ->
        state
        |> Map.put(String.to_atom("erpm_#{vesc_id}"), erpm)
        |> Map.put(String.to_atom("motor_current_#{vesc_id}"), motor_current * 0.1)

      _ ->
        state
    end
  end

  defp handle_can_vesc_helper_status_1(_packet, _vesc_id, state) do
    state
  end

  defp handle_can_vesc_helper_status_4(packet, vesc_id, state)
       when vesc_id in [101, 102, 103, 104] do
    case packet.data do
      <<_::integer-32, current::integer-big-16-signed, _::binary>> ->
        Map.put(state, String.to_atom("current_in_#{vesc_id}"), current * 0.1)

      _ ->
        state
    end
  end

  defp handle_can_vesc_helper_status_4(_packet, _vesc_id, state) do
    state
  end

  defp handle_can_packet_helper(packet, state) do
    case packet.identifier do
      <<0x180::integer-big-16>> ->
        handle_can_mhp_helper(packet, state)

      <<_, _, @vesc_status_1, vesc_id>> ->
        handle_can_vesc_helper_status_1(packet, vesc_id, state)

      <<_, _, @vesc_status_4, vesc_id>> ->
        handle_can_vesc_helper_status_4(packet, vesc_id, state)

      _ ->
        state
    end
  end
end

defmodule PropTest do
  def run() do
    # Prompt user for speed and angle
    speed = IO.gets("Enter speed in km/h: ") |> String.trim() |> String.to_integer()

    angle =
      IO.gets("Enter heading angle in deg [+90 facing forwards, -90 facing backwards]: ")
      |> String.trim()
      |> String.to_integer()

    csv_header =
      "epoch,force_x,force_y,force_z,p1,p2,p3,p4,p5,p6,p7,p8,temperature,erpm_101,erpm_102,erpm_103,erpm_104,current_in_101,current_in_102,current_in_103,current_in_104,motor_current_101,motor_current_102,motor_current_103,motor_current_104,speed,angle\n"

    #
    # CAN stuff to receive from the multi hole probe
    # We will have one process to receive packets, and one agent process to own the
    # data from the MHP
    #
    {:ok, _mhp_agent} = ProbeAndVESCAgent.start_link()

    _can_listener_pid =
      Task.async(fn ->
        Cannes.Dumper.start("can0")
        |> Cannes.Dumper.get_formatted_stream()
        |> Stream.each(fn packet -> ProbeAndVESCAgent.handle_can_packet(packet) end)
        |> Stream.run()
      end)

    # To test the reception of traffic, use:
    #  cansend vcan0 180#01.80.00.80.00.80.00.14
    #  cansend vcan0 180#02.80.00.80.00.09.CF.0A
    #  cansend vcan0 180#00.80.00.80.00.80.00.31
    #  cansend vcan0 180#01.80.00.80.00.80.00.14
    #  cansend vcan0 180#02.80.00.80.00.09.CF.0A
    #  cansend vcan0 180#00.80.00.80.00.80.00.31
    #  cansend vcan0 180#01.80.00.80.00.80.00.14
    #  cansend vcan0 180#02.80.00.80.00.09.CF.0A
    #  cansend vcan0 180#00.80.00.80.00.80.00.31
    #  cansend vcan0 180#01.80.00.80.00.80.00.14
    #  cansend vcan0 180#02.80.00.80.00.09.CF.0A
    # receive do
    #   :never ->
    #     :ok
    # end

    #
    # Modbus stuff
    #

    serial_gateway_ip = {192, 168, 0, 239}
    serial_gateway_port = 502

    # module default, 9600 baud rate
    # TODO: change values back to 1, 2, 3 when new amplifiers arrive!
    rtu_address_x = 3
    rtu_address_y = 3
    rtu_address_z = 3
    modbus_address_weight_holding_registers = 0x0000

    # ms
    polling_interval = 250

    {:ok, master} = Modbus.Master.start_link(ip: serial_gateway_ip, port: serial_gateway_port)

    polling_fun = fn ->
      read_modbus_regs = fn node_address ->
        {:ok, regs} =
          Modbus.Master.exec(
            master,
            {:rhr, node_address, modbus_address_weight_holding_registers, 2}
          )

        regs
      end

      regs_to_val = fn [r0, r1] ->
        <<result::integer-big-signed-size(32)>> =
          <<r0::integer-big-unsigned-size(16), r1::integer-big-unsigned-size(16)>>

        result
      end

      timestamp =
        DateTime.now!("Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      pressures = ProbeAndVESCAgent.get()

      pressure_temp_list = [
        pressures.p1,
        pressures.p2,
        pressures.p3,
        pressures.p4,
        pressures.p5,
        pressures.p6,
        pressures.p7,
        pressures.p8,
        pressures.temperature,
        pressures.erpm_101,
        pressures.erpm_102,
        pressures.erpm_103,
        pressures.erpm_104,
        pressures.current_in_101,
        pressures.current_in_102,
        pressures.current_in_103,
        pressures.current_in_104,
        pressures.motor_current_101,
        pressures.motor_current_102,
        pressures.motor_current_103,
        pressures.motor_current_104
      ]

      tmp =
        [rtu_address_x, rtu_address_y, rtu_address_z]
        |> Enum.map(read_modbus_regs)
        |> Enum.map(regs_to_val)
        |> Enum.concat(pressure_temp_list)
        |> Enum.concat([speed, angle])
        |> Enum.join(",")

      "#{timestamp},#{tmp}\n"
    end

    timestamp =
      DateTime.now!("Etc/UTC")
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:.-]/, "_")

    file_name = "proptest_logger_#{timestamp}_speed_#{speed}_angle_#{angle}.csv"

    add_csv_header_to_stream = fn enum -> Stream.concat([csv_header], enum) end

    Stream.interval(polling_interval)
    |> Stream.map(fn _ -> polling_fun.() end)
    |> add_csv_header_to_stream.()
    |> Stream.into(File.stream!(file_name))
    |> Stream.run()

    # this will block
  end
end

PropTest.run()
