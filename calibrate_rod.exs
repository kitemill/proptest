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

defmodule PropTest do
  def run() do
    
    IO.inspect(Circuits.UART.enumerate)

    {:ok, serial_pid} = Circuits.UART.start_link()
    Circuits.UART.open(serial_pid, "ttyUSB0", speed: 115200, active: false)


    for pwm1 <- 1100..1900//100, pwm2 <- 1100..1900//100 do
      IO.puts("x = #{pwm1}  y = #{pwm2}")
      Circuits.UART.write(serial_pid,<<0xff, pwm1::big-16, pwm2::big-16>>)
      _ = IO.gets("")
    end

  end
end


PropTest.run()
