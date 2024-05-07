#
# This script will download data from the three load sensors on the prop test
# rig and output them to a CSV file. It will also interface the multi hole
# probe. And also note the RPM coming from VESC with Id 101, 102, 103, 104, 105
#
# Run the script with
# $ elixir proptest_logger.exs
#

Mix.install(
  [
    # {:cannes, "~> 0.0.5"},
    {:cannes, github: "tallakt/cannes", branch: "master"},
    {:circuits_uart, "~> 1.4.3"},
  ],
  config: [porcelain: [driver: Porcelain.Driver.Basic]]
)

# This agent holds the data from the probe so it can be accessed asyncronically
defmodule ProbeAndVESCAgent do
  use Agent

  def start_link() do
    initial_value = %{p1: 0.0, p2: 0.0, p3: 0.0, p4: 0.0, p5: 0.0, p6: 0.0, p7: 0.0, p8: 0.0, temperature: 0.0, erpm_101: 0, erpm_102: 0, erpm_103: 0, erpm_104: 0}
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end


  def get() do
    Agent.get(__MODULE__, & &1)
  end


  def handle_can_packet(packet) do
    Agent.update(__MODULE__, fn state -> handle_can_packet_helper(packet, state) end )
  end


  defp evoscann_raw_to_mbar(x) do
    <<tmp::signed-16>> = <<(x - 32768)::integer-16>>
    tmp / 320.0
  end


  defp handle_can_packet_helper(packet, state) do
    # handle multi hole probe packets
    if <<0x180::integer-big-16>> = packet.identifier do
      case packet.data do
        <<0, p1::big-16, p2::big-16, p3::big-16, _::binary>> ->
          %{state | p1: evoscann_raw_to_mbar(p1), p2: evoscann_raw_to_mbar(p2), p3: evoscann_raw_to_mbar(p3)}
        <<1, p4::big-16, p5::big-16, p6::big-16, t::signed>> ->
          %{state | p4: evoscann_raw_to_mbar(p4), p5: evoscann_raw_to_mbar(p5), p6: evoscann_raw_to_mbar(p6), temperature: t}
        <<2, p7::big-16, p8::big-16, _::binary>> ->
          %{state | p7: evoscann_raw_to_mbar(p7), p8: evoscann_raw_to_mbar(p8)}
        _ ->
          state
      end
    end
  end
end


defmodule PropTest do
  def run() do
    csv_header = "epoch,servo1,servo2,p1,p2,p3,p4,p5,p6,p7,p8,temperature\n"

    #
    # CAN stuff to receive from the multi hole probe
    # We will have one process to receive packets, and one agent process to own the
    # data from the MHP
    #
    {:ok, _mhp_agent} = ProbeAndVESCAgent.start_link()

    _can_listener_pid = Task.async(fn ->
      Cannes.Dumper.start("vcan0")
      |> Cannes.Dumper.get_formatted_stream
      |> Stream.each(fn packet -> ProbeAndVESCAgent.handle_can_packet(packet) end)
      |> Stream.run
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
    # Serial stuff
    #
    
    IO.inspect(Circuits.UART.enumerate)

    {:ok, serial_pid} = Circuits.UART.start_link()
    Circuits.UART.open(serial_pid, "ttyUSB0", speed: 115200, active: false)

    polling_interval = 1000 # ms


    change_setpoints_fun = fn ->

      t = System.system_time(:millisecond)


      servo1_sp = round(1500 + 400.0 * :math.sin(t / 1000.0 / 51.0 * 3.141 * 2))
      servo2_sp = round(1500 + 400.0 * :math.sin(t / 1000.0 / 91.0 * 3.141 * 2))

      Circuits.UART.write(serial_pid,<<0xff, servo1_sp::big-16, servo2_sp::big-16>>)
      # Circuits.UART.write(serial_pid,<<0, 0xdead::big-16, 0xbeef::big-16>>)
      # Circuits.UART.write(serial_pid,<<0, 0x1122::big-16, 0x3344::big-16>>)
      # Circuits.UART.write(serial_pid,<<99, 98>>)
      IO.puts("Setting PWM values #{servo1_sp} and #{servo2_sp}")

      :timer.sleep(round(polling_interval / 2))

      timestamp =
        DateTime.now!("Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      pressures = ProbeAndVESCAgent.get()
      row = [
        servo1_sp,
        servo2_sp,
        pressures.p1,
        pressures.p2,
        pressures.p3,
        pressures.p4,
        pressures.p5,
        pressures.p6,
        pressures.p7,
        pressures.p8,
        pressures.temperature,
      ]

      "#{timestamp},#{Enum.join(row, ",")}\n"
    end

    timestamp = 
      DateTime.now!("Etc/UTC")
      |> DateTime.to_iso8601
      |> String.replace(~r/[:.-]/, "_")

    add_csv_header_to_stream = fn enum -> Stream.concat([csv_header], enum) end

    Stream.interval(polling_interval)
    |> Stream.map(fn _ -> change_setpoints_fun.() end)
    |> add_csv_header_to_stream.()
    |> Stream.into(File.stream!("_ai_multi_hole_probe_logger_#{timestamp}.csv"))
    |> Stream.run()
    # this will block

  end
end


PropTest.run()
