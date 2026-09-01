#
# This script will download data from the three load sensors on the prop test
# rig and output them to a CSV file. It listens for ESC telemetry over CAN
# using the TM-UAVCAN/DroneCAN protocol (EscStatus message type 1034) and
# logs voltage, current, RPM, throttle and temperature. The multi hole probe
# code path is kept (CAN-ID 0x180) but is not exercised in the current setup.
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
# If you reconect the USB adapter you may not be able to get CAN traffic back
# online. To reset slcand issue the command:
#
# $ sudo killall slcand
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
# EscStatus reports actual shaft RPM directly (int18, signed), so unlike the
# previous VESC setup no ERPM-to-RPM conversion is needed. The TM-UAVCAN
# protocol uses 29-bit extended CAN-IDs at 1 Mbps by default; check that the
# slcand baud rate flag (`-s`) matches the ESC's configured bus rate.
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
  import Bitwise

  @esc_status_msg_type_id 1034

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
      esc_voltage: -99.0,
      esc_current: -99.0,
      esc_temperature_c: -99.0,
      esc_rpm: -99,
      esc_throttle: -99,
      esc_status_bits: 0,
      # Multi-frame reassembly buffer keyed by {source_node_id, transfer_id}.
      # Holds the accumulated payload bytes (with tail bytes stripped) until
      # the End-of-transfer bit is seen.
      uavcan_buffers: %{}
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
    <<tmp::signed-16>> = <<(x - 32768)::integer-16>>
    tmp / 1600.0
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

  # UAVCAN/DroneCAN: tail byte is the last byte of every CAN frame and carries
  # <<start_of_transfer::1, end_of_transfer::1, toggle::1, transfer_id::5>>.
  # Single-frame transfers have start=1, end=1.
  # For multi-frame, the first frame additionally has a 2-byte transfer CRC at
  # the start of its payload (we discard it — single ESC, short bus, no CRC check).
  defp handle_can_uavcan_esc(frame_data, source_node_id, state) do
    payload_size = byte_size(frame_data) - 1
    <<payload::binary-size(payload_size), tail::8>> = frame_data
    <<sot::1, eot::1, _toggle::1, transfer_id::5>> = <<tail>>

    case {sot, eot} do
      {1, 1} ->
        parse_esc_status(payload, state)

      {1, 0} ->
        <<_crc::binary-size(2), rest::binary>> = payload
        key = {source_node_id, transfer_id}
        put_in(state.uavcan_buffers[key], rest)

      {0, 0} ->
        key = {source_node_id, transfer_id}

        case Map.fetch(state.uavcan_buffers, key) do
          {:ok, acc} -> put_in(state.uavcan_buffers[key], acc <> payload)
          :error -> state
        end

      {0, 1} ->
        key = {source_node_id, transfer_id}

        case Map.fetch(state.uavcan_buffers, key) do
          {:ok, acc} ->
            # SocketCAN/cannes always delivers 8-byte frames regardless of the
            # CAN frame's actual DLC, so the last frame carries trailing padding.
            # EscStatus is fixed at 14 bytes — trim to that.
            full = binary_part(acc <> payload, 0, 14)
            state = update_in(state.uavcan_buffers, &Map.delete(&1, key))
            parse_esc_status(full, state)

          :error ->
            state
        end
    end
  end

  # EscStatus(1034) — 14 bytes per TM-UAVCAN v2.3.
  # Byte 1-4  : status (uint32 LE)
  # Byte 5-6  : voltage (float16 LE) — volts
  # Byte 7-8  : current (float16 LE) — amperes
  # Byte 9-10 : temperature (float16 LE) — kelvin
  #
  # The remaining fields are int18 rpm, uint7 power_rating_pct and uint5
  # esc_index. That is 30 bits, so they are bit-packed LSB-first and do NOT sit
  # on byte boundaries:
  #
  #   byte 11: rpm bits 0-7
  #   byte 12: rpm bits 8-15
  #   byte 13: rpm bits 16-17, then throttle bits 0-5
  #   byte 14: throttle bit 6, then esc_index bits 0-4
  #
  # Reading byte 11-12 as a plain int16 happens to give the right rpm for
  # positive values below 32768, which is why it looked correct — but throttle
  # spans two bytes and read as zero. Unpack the bits explicitly instead.
  defp parse_esc_status(payload, state) do
    case payload do
      <<status::little-32, voltage_f16::little-16, current_f16::little-16,
        temp_f16::little-16, b11::8, b12::8, b13::8, b14::8>> ->
        rpm_raw = b11 ||| (b12 <<< 8) ||| ((b13 &&& 0x03) <<< 16)

        %{
          state
          | esc_status_bits: status,
            esc_voltage: float16_to_float(voltage_f16),
            esc_current: float16_to_float(current_f16),
            esc_temperature_c: float16_to_float(temp_f16) - 273.15,
            # int18 two's complement
            esc_rpm: if(rpm_raw >= 0x20000, do: rpm_raw - 0x40000, else: rpm_raw),
            esc_throttle: ((b13 >>> 2) &&& 0x3F) ||| ((b14 &&& 0x01) <<< 6)
        }

      _ ->
        state
    end
  end

  # IEEE 754 half-precision (float16) to float32. Algorithm from TM-UAVCAN
  # appendix 5.2 (ConvertFloat16ToFloat) — re-cast bits as float32, scale by
  # magic constant, then handle inf/nan and re-apply sign.
  defp float16_to_float(value) do
    sign_bit = (value &&& 0x8000) <<< 16
    exp_mant_u = (value &&& 0x7FFF) <<< 13
    <<exp_mant_f::float-32>> = <<exp_mant_u::32>>
    <<magic_f::float-32>> = <<((254 - 15) <<< 23)::32>>
    <<inf_nan_f::float-32>> = <<((127 + 16) <<< 23)::32>>
    scaled = exp_mant_f * magic_f
    <<scaled_u::32>> = <<scaled::float-32>>
    scaled_u = if scaled >= inf_nan_f, do: scaled_u ||| 255 <<< 23, else: scaled_u
    <<f::float-32>> = <<scaled_u ||| sign_bit::32>>
    f
  end

  defp handle_can_packet_helper(packet, state) do
    case packet.identifier do
      <<0x180::integer-big-16>> ->
        handle_can_mhp_helper(packet, state)

      <<_::3, _priority::5, @esc_status_msg_type_id::16, _service::1, source_node_id::7>> ->
        handle_can_uavcan_esc(packet.data, source_node_id, state)

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
      "epoch,force_x,force_y,force_z,p1,p2,p3,p4,p5,p6,p7,p8,temperature,esc_voltage,esc_current,esc_rpm,esc_throttle,esc_temperature_c,esc_status_bits,speed,angle\n"

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
    rtu_address_x = 1 # +left
    rtu_address_y = 2 # +up
    rtu_address_z = 3 # +aft
    modbus_address_weight_holding_registers = 0x0000

    # ms
    polling_interval = 250

    {:ok, master} = Modbus.Master.start_link(ip: serial_gateway_ip, port: serial_gateway_port)

    polling_fun = fn ->
      read_modbus_regs = fn node_address ->
        try do
          {:ok, regs} =
            Modbus.Master.exec(
              master,
              {:rhr, node_address, modbus_address_weight_holding_registers, 2}
            )

          regs
        rescue
          _ -> [0, 0] # this happens when motors start sometimes
        end
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
        pressures.esc_voltage,
        pressures.esc_current,
        pressures.esc_rpm,
        pressures.esc_throttle,
        pressures.esc_temperature_c,
        pressures.esc_status_bits
      ]

      tmp =
        [rtu_address_x, rtu_address_y, rtu_address_z]
        |> Enum.map(read_modbus_regs)
        |> Enum.map(regs_to_val)
        |> Enum.concat(pressure_temp_list)
        |> Enum.concat([speed, angle])
        |> Enum.join(",")

      if :rand.uniform(50) == 1 do
        ~w(p1 p2 p3 p4 p5 p6 p7 p8 temperature esc_voltage esc_current esc_rpm esc_throttle esc_temperature_c esc_status_bits)
        |> Enum.zip(pressure_temp_list)
        |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
        |> Enum.join(", ")
        |> IO.puts()
      end

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
