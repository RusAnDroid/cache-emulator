`include "memory.sv"
`include "cache.sv"
`include "CPU.sv"

module testbench
  #(
    parameter ADDR1_BUS_SIZE = 15,
    parameter DATA1_BUS_SIZE = 16,
    parameter CTR1_BUS_SIZE = 3,
    parameter ADDR2_BUS_SIZE = 15,
    parameter DATA2_BUS_SIZE = 16,
    parameter CTR2_BUS_SIZE = 2
  );

  wire[(ADDR1_BUS_SIZE - 1):0] a1;
  wire[(DATA1_BUS_SIZE - 1):0] d1;
  wire[(CTR1_BUS_SIZE - 1):0] c1;

  wire[(ADDR2_BUS_SIZE - 1):0] a2;
  wire[(DATA2_BUS_SIZE - 1):0] d2;
  wire[(CTR2_BUS_SIZE - 1):0] c2;

  reg clk, reset, m_dump, c_dump;
  int clk_counter;

  reg is_cpu_done;

  memory memory_inst(clk, reset, m_dump, a2, d2, c2);
  cache cache_inst(clk, reset, c_dump, a1, d1, c1, a2, d2, c2);
  CPU cpu_inst(clk, a1, d1, c1, is_cpu_done);

  initial begin
    
    reset = 0;
    m_dump = 0;
    c_dump = 0;
    clk = 0;
    clk_counter = 0;

    while (is_cpu_done == 0 && clk_counter < 100000000) begin
      clk = (clk + 1) % 2;
      if (is_cpu_done < 1 && clk == 1) begin
        clk_counter++;
      end
      #1;
    end

    $display("Total clocks: %0d", clk_counter);

  end

endmodule