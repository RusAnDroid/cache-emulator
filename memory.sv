module memory
  #(
    parameter CACHE_LINE_SIZE = 16,
    parameter CACHE_OFFSET_SIZE = 4,
    parameter ADDR2_BUS_SIZE = 15,
    parameter DATA2_BUS_SIZE = 16,
    parameter CTR2_BUS_SIZE = 2,
    parameter MEM_SIZE = 512,
    parameter MEMORY_RESPONSE_TIME = 100,
    parameter _SEED = 225526
  )
  (
    input CLK, 
    input RESET, 
    input M_DUMP,
    inout[(ADDR2_BUS_SIZE - 1):0] A2, 
    inout[(DATA2_BUS_SIZE - 1):0] D2, 
    inout[(CTR2_BUS_SIZE - 1):0] C2
  );
  
  reg[7:0] data[(MEM_SIZE * 1024 - 1):0];

  // Регистр, привязанный к шине, имеет такое же имя, как и соответсвующая ему шина, но мальенькими буквами
  reg[(CTR2_BUS_SIZE - 1):0] c2;
  reg[(DATA2_BUS_SIZE - 1):0] d2;

  assign D2 = d2;
  assign C2 = c2;

  reg[(ADDR2_BUS_SIZE - 1):0] address_buffer;

  int SEED;

  int file;

  task automatic dump();
    begin

      file = $fopen("m_dump.txt", "w");
      for (int line = 0; line < MEM_SIZE * 1024 / CACHE_LINE_SIZE; line++) begin
        $fwrite(file, "address %h: ", (line << CACHE_OFFSET_SIZE));
        for (int i = 0; i < CACHE_LINE_SIZE; i++) begin
          $fwrite(file, "%h ", data[(line << CACHE_OFFSET_SIZE) + i]);
        end
        $fdisplay(file);
      end
      $fclose(file);

    end
  endtask

  task automatic wait_posedge (input int times);
    begin
      repeat (times) begin
        @ (posedge CLK);
      end
    end
  endtask

  task automatic wait_negedge (input int times);
    begin
      repeat (times) begin
        @ (negedge CLK);
      end
    end
  endtask

  // отдать шину
  task automatic give_away_bus();
    begin

        c2 = 'z;
        d2 = 'z;

    end
  endtask

  task automatic reset();
    begin

      SEED = _SEED;

      give_away_bus();

      for (int i = 0; i < MEM_SIZE * 1024; i++) begin
        data[i] = $random(SEED) >> 16;  
      end

    end
  endtask

  initial begin
    reset();
  end
  
  always @ (posedge CLK) begin

    if (RESET == 1) begin
      reset();
    end
    
    if (M_DUMP == 1) begin
      dump();
    end

    if (C2 == 2) begin // C2_READ_LINE

      // Читаем адрес в буфер
      address_buffer = A2;

      // забираем владение шиной
      @ (negedge CLK);
      c2 = 0;

      // Ждём нужное количество тактов и начинаем отправлять ответ
      wait_negedge(MEMORY_RESPONSE_TIME);
      c2 = 1;

      for (int i = CACHE_LINE_SIZE - 1; i >= 0; i -= 2) begin
        d2 = (data[(address_buffer << CACHE_OFFSET_SIZE) + i - 1] << 8) + data[(address_buffer << CACHE_OFFSET_SIZE) + i];
        
        // ждём следующего такта
        @ (negedge CLK);
      end

      // отдаём владение шиной (такт уже подождали)
      give_away_bus();

    end
    else if (C2 == 3) begin // C2_WRITE_LINE

      // Адрес держится всё время передачи, можем спокойно записать всё, что надо
      for (int i = CACHE_LINE_SIZE - 1; i >= 0; i -= 2) begin
        data[(A2 << CACHE_OFFSET_SIZE) + i - 1] = (D2 >> 8);
        data[(A2 << CACHE_OFFSET_SIZE) + i] = D2 % (1 << 8);

        // ждём следующий такт
        @ (negedge CLK);
      end

      // т.к. в конце цикла мы всё равно уже подождали такт, можем забрать управление шиной
      c2 = 0;

      // ждём нужное количество тактов
      wait_negedge(MEMORY_RESPONSE_TIME - (CACHE_LINE_SIZE / 2 - 1));

      // отвечаем, что всё прошло успешно
      c2 = 1;
      
      // отдаём владение шиной
      @ (negedge CLK);
      give_away_bus();

    end
  end
  
endmodule