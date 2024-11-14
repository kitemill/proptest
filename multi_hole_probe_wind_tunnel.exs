#
# This script will download data  the prop test
# rig and output them to a CSV file. It will also interface the multi hole
# probe. 
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

Mix.install(
  [
    {:cannes, github: "tallakt/cannes", branch: "master"}
  ],
  config: [porcelain: [driver: Porcelain.Driver.Basic]]
)

# This agent holds the data from the probe so it can be accessed asyncronically
defmodule ProbeAndVESCAgent do
  use Agent


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

  defp handle_can_packet_helper(packet, state) do
    case packet.identifier do
      <<0x190::integer-big-16>> ->
        handle_can_mhp_helper(packet, state)
      _ ->
        state
    end
  end
end

defmodule PropTest do
  def run() do
    csv_header =
      "epoch,p1,p2,p3,p4,p5,p6,p7,p8,temperature\n"

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


    polling_fun = fn ->
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
      ]

      tmp =
        pressure_temp_list
        |> Enum.join(",")

      "#{timestamp},#{tmp}\n"
    end

    timestamp =
      DateTime.now!("Etc/UTC")
      |> DateTime.to_iso8601()
      |> String.replace(~r/[:.-]/, "_")

    file_name = "proptest_logger_#{timestamp}.csv"

    Stream.interval(polling_interval)
    |> Stream.map(fn _ -> polling_fun.() end)
    |> (fn enum -> Stream.concat([csv_header], enum) end).()
    |> Stream.into(File.stream!(file_name))
    |> Stream.run()

    # this will block
  end
end

PropTest.run()
