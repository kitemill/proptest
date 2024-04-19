#
# This script will download data from the three load sensors on the prop test
# rig and output them to a CSV file.
#
# Run the script with
# $ elixir proptest_logger.exs
#

Mix.install([
  {:modbus, "~> 0.4.0"},
])


serial_gateway_ip = {192, 168, 0, 239}
serial_gateway_port = 502

rtu_address_x = 1 # module default, 9600 baud rate
rtu_address_y = 2
rtu_address_z = 3
modbus_address_weight_holding_registers = 0x0000

polling_interval = 250 # ms

csv_header = "epoch,force_x,force_y,force_z\n"

{:ok, master} = Modbus.Master.start_link(ip: serial_gateway_ip, port: serial_gateway_port)

polling_fun = fn ->
  read_modbus_regs = fn (node_address) ->
    {:ok , regs} = Modbus.Master.exec(master, {:rhr, node_address, modbus_address_weight_holding_registers, 2})
    regs
  end

  regs_to_val = fn [r0, r1] ->
    <<result::integer-big-signed-size(32)>> = <<r0::integer-big-unsigned-size(16), r1::integer-big-unsigned-size(16)>>
    result
  end

  timestamp =
    DateTime.now!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)

  tmp = 
    [rtu_address_x, rtu_address_y, rtu_address_z]
    |> Enum.map(read_modbus_regs)
    |> Enum.map(regs_to_val)
    |> Enum.join(",")
  "#{timestamp},#{tmp}\n"
end

timestamp = 
  DateTime.now!("Etc/UTC")
  |> DateTime.to_iso8601
  |> String.replace(~r/[:.-]/, "_")

output = File.stream!("proptest_logger_#{timestamp}.csv")

add_csv_header_to_stream = fn enum -> Stream.concat([csv_header], enum) end

Stream.interval(polling_interval)
|> Stream.map(fn _ -> polling_fun.() end)
|> add_csv_header_to_stream.()
|> Stream.into(output)
|> Stream.run()

