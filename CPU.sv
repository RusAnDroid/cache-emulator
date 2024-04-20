module CPU
  #(
    parameter ADDR1_BUS_SIZE = 15,
    parameter DATA1_BUS_SIZE = 16,
    parameter CTR1_BUS_SIZE = 3,
    parameter CACHE_TAG_SIZE = 10,
    parameter CACHE_SET_SIZE = 5,
    parameter CACHE_OFFSET_SIZE = 4,
    parameter M = 64,
    parameter N = 60,
    parameter K = 32
  )
  (
    input CLK, 
    inout[(ADDR1_BUS_SIZE - 1):0] A1, 
    inout[(DATA1_BUS_SIZE - 1):0] D1, 
    inout[(CTR1_BUS_SIZE - 1):0] C1,
    output ANS
  );
  

  // Регистр, привязанный к шине, имеет такое же имя, как и соответсвующая ему шина, но мальенькими буквами
  reg[(CTR1_BUS_SIZE - 1):0] c1;
  reg[(DATA1_BUS_SIZE - 1):0] d1;
  reg[(ADDR1_BUS_SIZE - 1):0] a1;

  assign C1 = c1;
  assign D1 = d1;
  assign A1 = a1;

  reg ans;
  assign ANS = ans;

  int A_SIZE, B_SIZE, C_SIZE;
  int pa, pb, pc;
  int s;
  int pa_data, pb_data, pc_data;
  int waiting_couter;

  int cache_hits, cache_requests;

  // отдать шину
  task automatic give_away_bus();
    begin

        a1 = 'z;
        c1 = 'z;
        d1 = 'z;

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

  // таска чтения (читаем на выходе int)
  task automatic read(input int address, input int command_id, output int out);
    begin
      cache_requests++;

      // не надо ждать negedge, т.к. мы никогда не придём сюда в posedge

      // отправляем запрос на запись
      c1 = command_id;
      a1 = address >> CACHE_OFFSET_SIZE;

      // через такт отправляем offset
      @ (negedge CLK);
      a1 = address % (1 << CACHE_OFFSET_SIZE);

      // отдаём управление шиной
      @ (negedge CLK);
      give_away_bus();

      waiting_couter = 0;

      // ждём ответа от кэша
      do begin
        @ (posedge CLK);
        waiting_couter++;
      end while (C1 !== 7); // C1_RESPONSE

      // если кэш ответил меньше, чем за 100 тактов, то это кэш-попадание
      if (waiting_couter < 100) begin
        cache_hits++;
      end

      // записываем, что нам отправил кэш
      out = D1;

      if (command_id == 3) begin // C1_READ32
        // если мы запросили 32 бита, что через такт считаем ещё 16 (старших)
        out += D1 << 16;
      end

      // забираем управление шиной
      @ (negedge CLK);
      c1 = 0;

    end
  endtask

  // такска записи (на вход данные подаются в виде int)
  task automatic write(input int address, input int command_id, input int data);
    begin
      cache_requests++;

      // не надо ждать negedge, т.к. мы никогда не придём сюда в posedge

      // отправляем запрос на запись
      c1 = command_id;
      a1 = address >> CACHE_OFFSET_SIZE;
      d1 = data % (1 << 16);

      // через такт отправляем offset
      @ (negedge CLK);
      a1 = address % (1 << CACHE_OFFSET_SIZE);

      if (command_id == 7) begin // C1_WRITING32
        // если хотим записать 32 бита, то в такт отправки offset отправляем и их
        d1 = data >> 16;
      end

      // отдаём управление шиной
      @ (negedge CLK);
      give_away_bus();

      waiting_couter = 0;

      // ждём ответа от кэша
      do begin
        @ (posedge CLK);
        waiting_couter++;
      end while (C1 !== 7); // C1_RESPONSE

      // если кэш ответил меньше, чем за 100 тактов, то это кэш-попадание
      if (waiting_couter < 100) begin
        cache_hits++;
      end

      // забираем управление шиной
      @ (negedge CLK);
      c1 = 0;

    end
  endtask

  initial begin
    
    give_away_bus();
    c1 = 0;

    A_SIZE = M * K;
    B_SIZE = K * N * 2;
    C_SIZE = M * N * 4;

    cache_hits = 0;
    cache_requests = 0;
    ans = 0;

    /*
      Вот отсюда начинается функция, которую нужно промоделировать.
      Пусть у CPU синхронизация по negedge 
      (т.к. он только отправляет запросы и принимает ответы)
    */
    @ (negedge CLK);

    $display("CPU: start");
    
    pa = 0;
    wait_negedge(1); // инициализация переменной

    pc = A_SIZE + B_SIZE;
    wait_negedge(1); // инициализация переменной
  
    for (int y = 0; y < M; y++) begin
      wait_negedge(1); // переход на новую итерацию цикла (а на первой итерации инициализация переменной y)

      for (int x = 0; x < N; x++) begin
        wait_negedge(1); // переход на новую итерацию цикла (а на первой итерации инициализация переменной x)

        pb = A_SIZE;
        wait_negedge(1); // инициализация переменной

        s = 0;
        wait_negedge(1); // инициализация переменной

        for (int k = 0; k < K; k++) begin
          wait_negedge(1); // переход на новую итерацию цикла (а на первой итерации инициализация переменной k) 

          read(pa + k, 1, pa_data); // C1_READ8
          read(pb + 2 * x, 2, pb_data); // C1_READ16

          s += pa_data + pb_data;
          wait_negedge(6); // сложение и умножение

          pb += 2 * N;
          wait_negedge(1); // сложение
        end
        
        write(pc + 4 * x, 7, s); // C1_WRITE32 
      end

      pa += K;
      wait_negedge(1); // сложение

      pc += 4 * N;
      wait_negedge(1); // сложение

    end

    $display("CPU: done");
    $display("Cahce-hits: %0d / %0d = %.2f", cache_hits, cache_requests, real'(cache_hits) / real'(cache_requests) * 100);
    ans = 1;

  end
endmodule