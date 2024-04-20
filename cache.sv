

module cache
  #(
    parameter CACHE_WAY = 2,
    parameter CACHE_SETS_COUNT = 32,
    parameter ADDR1_BUS_SIZE = 15,
    parameter DATA1_BUS_SIZE = 16,
    parameter CTR1_BUS_SIZE = 3,
    parameter CACHE_LINE_SIZE = 16,
    parameter CACHE_TAG_SIZE = 10,
    parameter CACHE_SET_SIZE = 5,
    parameter CACHE_OFFSET_SIZE = 4,
    parameter ADDR2_BUS_SIZE = 15,
    parameter DATA2_BUS_SIZE = 16,
    parameter CTR2_BUS_SIZE = 2,
    parameter CACHE_HIT_RESPONSE_TIME = 5,
    parameter CACHE_MISS_RESPONSE_TIME = 3
  )
  (
    input CLK, 
    input RESET, 
    input C_DUMP,
    inout[(ADDR1_BUS_SIZE - 1):0] A1, 
    inout[(DATA1_BUS_SIZE - 1):0] D1, 
    inout[(CTR1_BUS_SIZE - 1):0] C1,
    inout[(ADDR2_BUS_SIZE - 1):0] A2, 
    inout[(DATA2_BUS_SIZE - 1):0] D2, 
    inout[(CTR2_BUS_SIZE - 1):0] C2
  );

  reg[7:0] sets[(CACHE_SETS_COUNT - 1):0][(CACHE_WAY - 1):0][(CACHE_LINE_SIZE - 1):0];
  reg[(CACHE_TAG_SIZE - 1):0] tags[(CACHE_SETS_COUNT - 1):0][(CACHE_WAY - 1):0];
  reg valid[(CACHE_SETS_COUNT - 1):0][(CACHE_WAY - 1):0];
  reg dirty[(CACHE_SETS_COUNT - 1):0][(CACHE_WAY - 1):0];
  reg lru[(CACHE_SETS_COUNT - 1):0][(CACHE_WAY - 1):0];

  // Регистр, привязанный к шине, имеет такое же имя, как и соответсвующая ему шина, но мальенькими буквами
  reg[(CTR1_BUS_SIZE - 1):0] c1;
  reg[(DATA1_BUS_SIZE - 1):0] d1;

  reg[(CTR2_BUS_SIZE - 1):0] c2;
  reg[(DATA2_BUS_SIZE - 1):0] d2;
  reg[(DATA2_BUS_SIZE - 1):0] a2;

  reg[(CACHE_TAG_SIZE - 1):0] tag;
  reg[(CACHE_SET_SIZE - 1):0] set;
  reg[(CACHE_OFFSET_SIZE - 1):0] offset;

  assign D1 = d1;
  assign C1 = c1;

  assign A2 = a2;
  assign D2 = d2;
  assign C2 = c2;

  reg[31:0] data_buffer;
  
  int c1_buffer;

  int cache_hit, empty_line;

  int file;

  task automatic dump();
    begin

      file = $fopen("c_dump.txt", "w");

      for (int cur_set = 0; cur_set < CACHE_SETS_COUNT; cur_set++) begin
        $fdisplay(file, "set %h: ", cur_set);

        for (int cur_line = 0; cur_line < CACHE_WAY; cur_line++) begin
          $fwrite(file, "        line %h: ", cur_line);

          for (int i = 0; i < CACHE_LINE_SIZE; i++) begin
            $fwrite(file, "%h ", sets[cur_set][cur_line][i]);
          end

          $fdisplay(file);
        end

        $fdisplay(file);
      end

      $fclose(file);

    end
  endtask

  task automatic wait_posedge(input int times);
    begin
      repeat (times) begin
        @ (posedge CLK);
      end
    end
  endtask

  task automatic wait_negedge(input int times);
    begin
      repeat (times) begin
        @ (negedge CLK);
      end
    end
  endtask

  task automatic read();
    begin
      
      // запоминаем, какая именно команда нам пришла
      c1_buffer = C1;

      if (c1_buffer >= 5 && c1_buffer <= 7) begin // C1_WRITE
        // если это команда на запись, то сохраняем пришедшие данные
        data_buffer = D1;
      end

      // читаем первую часть адреса
      tag = A1 >> CACHE_SET_SIZE;
      set = A1 % (1 << CACHE_SET_SIZE);

      // читаем offset в следующий такт
      @ (posedge CLK);
      offset = A1;

      if (c1_buffer == 7) begin // C1_WRITE32
        // если это команда на запись 32 бит, то надо запомнить ещё 16 бит
        data_buffer += D1 << 16;
      end

      // забираем владение шиной
      @ (negedge CLK);
      c1 = 0;
    end
  endtask

  // отдать шину
  task automatic give_away_bus(input bus_id);
    begin

      if (bus_id == 1) begin
        
        c1 = 'z;
        d1 = 'z;

      end
      else begin
        
        c2 = 'z;
        d2 = 'z;
        a2 = 'z;

      end

    end
  endtask

  task automatic write_dirty_line_to_memory(input int line_id);
    begin

      c2 = 3; // C2_WRITE_LINE
      a2 = (tag << CACHE_SET_SIZE) + set;
      for (int i = CACHE_LINE_SIZE - 1; i >= 0; i -= 2) begin
        d2 = (sets[set][line_id][i - 1] << 8) + sets[set][line_id][i];
        
        @ (negedge CLK); // отправили первую порцию данных и ждём такт
      end

      // в конце цикла уже подождали такт, поэтому можем сразу отдать владение шиной
      give_away_bus(2);

      // Ждём от памяти ответа, что всё записалось
      do begin
        @ (posedge CLK);
      end while (C2 !== 1); // C2_RESPONSE

      // т.к. мы записали эту линию, она больше не хранит незаписанные данные
      dirty[set][line_id] = 0;

    end
  endtask

  // эта таска обрабатывет случай кэш-промоха (просит у памяти нужную линию, предварительно вымещая самую старую, если это требуется)
  task automatic get_line();
    begin
      
      /* 
        Дальше надо обращаться в память, сразу подождём нужное количество тактов

        Ждём на один такт меньше указанного, т.к. если линия грязная и её нужно записать в память, 
        после того, как мы дождёмся ответа, будет posedge, и надо будет подождать, перед тем, 
        как просить память прочитать ещё одну линию.

        Но, если мы не записывали грязную линию, то перед запросом на чтение подождём лишний такт
      */
      wait_negedge(CACHE_MISS_RESPONSE_TIME - 1);

      empty_line = -1;

      for (int i = 0; i < CACHE_WAY; i++) begin
        if (valid[set][i] == 0 && empty_line == -1) begin 
          // Нашли невалидную линию
          empty_line = i;
        end
      end

      if (empty_line == -1) begin
        // Не нашли невалидную линию, а, значит, надо освобождать (замещать) одну линию

        for (int i = 0; i < CACHE_WAY; i++) begin
          if (lru[set][i] == 1) begin
            // Нашли наиболее старую линию (ту, которую надо заместить)
            empty_line = i;
          end
        end

        if (dirty[set][empty_line] == 1) begin
          // В линии, которую хотим заместить, хранятся незаписанные в память данные

          /*
            Ждём один "потерянный" такт и отправляем запрос на чтение
            
            Этими шинами по умолчанию владеет кэш, а память забирает только на время ответа на запрос,
            так что можно спокойно передавать по ним данные
          */
          @ (negedge CLK);
          write_dirty_line_to_memory(empty_line);
        end
      end

      // т.к. до этого мог быть запрос на запись, и, соответсвенно, сейчас posedge, надо подождать
      @ (negedge CLK);
      c2 = 2; // C2_READ_LINE
      a2 = (tag << CACHE_SET_SIZE) + set; 

      // отадём владение шиной
      @ (negedge CLK);
      give_away_bus(2);
      
      // Ждём от памяти ответа
      do begin
        @ (posedge CLK);
      end while (C2 !== 1); // C2_RESPONSE

      for (int i = CACHE_LINE_SIZE - 1; i >= 0; i -= 2) begin
        sets[set][empty_line][i - 1] = (D2 >> 8);
        sets[set][empty_line][i] = D2 % (1 << 8);

        // если есть следующая порция данных, то ждём такт
        if (i > 1) begin
          @ (posedge CLK);
        end
      end

      // забираем владение шиной
      @ (negedge CLK);
      c2 = 0;

      // обновляем массив последнего использования линий
      lru[set][empty_line] = 0;
      lru[set][(empty_line + 1) % 2] = 1;

      tags[set][empty_line] = tag;
      valid[set][empty_line] = 1;

    end
  endtask

  task automatic reset();
    begin
    
      give_away_bus(1);
    
      give_away_bus(2);
      c2 = 0;

      for (int i = 0; i < CACHE_SETS_COUNT; i++) begin
        for (int j = 0; j < CACHE_WAY; j++) begin
          valid[i][j] = 0;
          dirty[i][j] = 0;
          lru[i][j] = 1;
          tags[i][j] = 0;
        end
      end

    end
  endtask

  task automatic send_reading_response(input int line_id);
    begin

      // эта функция не вызывается в posedge, так что не надо ждать лишний такт
      c1 = 7; // C1_RESPONSE

      case (c1_buffer)
          1: // C1_READ8
          begin
            d1 = sets[set][line_id][offset];
          end

          2: // C1_READ16
          begin
            d1 = (sets[set][line_id][offset] << 8) + sets[set][line_id][offset + 1];
          end

          3: // C1_READ32
          begin
            // передаём сначала младшие 16 бит
            d1 = (sets[set][line_id][offset + 2] << 8) + sets[set][line_id][offset + 3];

            // через такт старшие
            @ (negedge CLK);
            d1 = (sets[set][line_id][offset] << 8) + sets[set][line_id][offset + 1];
          end
      endcase

    end
  endtask

  task automatic write_data_from_data_buffer(input int line_id);
    begin

      case (c1_buffer)
          5: // C1_WRITE8
          begin
            sets[set][line_id][offset] = data_buffer;
          end

          6: // C1_WRITE16
          begin
            sets[set][line_id][offset + 1] = data_buffer % (1 << 8);
            sets[set][line_id][offset] = data_buffer >> 8;
          end

          7: // C1_WRITE32
          begin
            sets[set][line_id][offset + 3] = data_buffer % (1 << 8);
            sets[set][line_id][offset + 2] = (data_buffer >> 8) % (1 << 8);
            sets[set][line_id][offset + 1] = (data_buffer >> 16) % (1 << 8);
            sets[set][line_id][offset] = data_buffer >> 24;
          end
      endcase

      // теперь эта линия хранит незаписанные в память данные
      dirty[set][line_id] = 1;

    end
  endtask

  initial begin
    reset();
  end
  
  always @ (posedge CLK) begin

    if (RESET == 1) begin
      reset();
    end

    if (C_DUMP == 1) begin
      dump();
    end
    
    if (C1 >= 1 && C1 <= 3) begin // C1_READ

      // читаем адрес и забираем владение шиной
      read();

      cache_hit = 0;

      for (int i = 0; i < CACHE_WAY; i++) begin
        if (tags[set][i] == tag && valid[set][i] == 1) begin
          // Кэш-хит!
          cache_hit = 1;

          // Надо обновить массив, испольюзующийся для определения наиболее старой кэш-линии:
          // теперь эта линия - самая свежая, а вторая - самая старая в сете (т.к. в сете по ТЗ всего 2 линии)
          lru[set][i] = 0;
          lru[set][(i + 1) % 2] = 1;

          // Ждём положенное количество тактов
          wait_negedge(CACHE_HIT_RESPONSE_TIME);

          // т.к. мы дождались negedge, можем отпаравлять данные по шине
          send_reading_response(i);

          // отдаём управление
          @ (negedge CLK);
          give_away_bus(1);

        end
      end

      if (cache_hit == 0) begin
        // Кэш-промах
        get_line();

        // отправляем ответ
        send_reading_response(empty_line);

        // в конце отдаём управление шиной
        @ (negedge CLK);
        give_away_bus(1);

      end

    end
    else if (C1 == 4) begin // C1_INVALIDATE_LINE
      // читаем адрес и забираем владение шиной
      read();

      cache_hit = 0;

      for (int i = 0; i < CACHE_WAY; i++) begin
        if (tags[set][i] == tag && valid[set][i] == 1) begin
          // нашли линию с таки тегом, значит, это кэш-хит, ждём нужное количество тактов и инвалидируем
          wait_negedge(CACHE_HIT_RESPONSE_TIME);

          // если линия грязная, то отправляем её в память
          if (dirty[set][i] == 1) begin
            write_dirty_line_to_memory(i);
          end

          valid[set][i] = 0;
          cache_hit = 1;
        end
      end

      if (cache_hit == 0) begin
        // это кэш-промах, значит, просто ждём нужное количество тактов
        wait_negedge(CACHE_MISS_RESPONSE_TIME);
      end

      // уже дождались negedge, отправляем ответ
      c1 = 7;
      
      // отдаём управление шиной
      @ (negedge CLK);
      give_away_bus(1);
      
    end
    else if (C1 >= 5 && C1 <= 7) begin // C1_WRITE

      // читаем адрес, данные и забираем управление шиной
      read();

      cache_hit = 0;

      for (int i = 0; i < CACHE_WAY; i++) begin
        if (tags[set][i] == tag && valid[set][i] == 1) begin
          // Кэш-хит!

          cache_hit = 1;

          // записываем в нужную линию данные
          write_data_from_data_buffer(i);

          // обновляем массив последнего использования линий
          lru[set][i] = 0;
          lru[set][(i + 1) % 2] = 1;

          // Ждём нужное количество тактов (negedge, т.к. собираемся отправлять ответ)
          wait_negedge(CACHE_HIT_RESPONSE_TIME);

          // negedge, можем отвечать, что всё хорошо
          c1 = 7; // C1_RESPONSE;

          // отдаём владение шиной
          @ (negedge CLK);
          give_away_bus(1);

        end
      end

      if (cache_hit == 0) begin
        // Кэш-мисс

        get_line();

        // записываем данные, которые нам прислал процессор
        write_data_from_data_buffer(empty_line);

        // можем отвечать, что всё хорошо, уже negedge, т.к. мы ждали, чтоб забрать владение данными
        c1 = 7; // C1_RESPONSE;

        // отдаём владение шиной
        @ (negedge CLK);
        give_away_bus(1);

      end
 
    end
  end
  
endmodule