#include <iostream>
#include <vector>
#include <map>
#include <algorithm>
#include <set>

using namespace std;

const int CACHE_WAY = 2;
const int CACHE_SETS_COUNT = 32;
const int CACHE_LINE_SIZE = 16;
const int MEM_SIZE = 512;
const int CACHE_OFFSET_SIZE = 4;
const int CACHE_SET_SIZE = 5;
const int CACHE_TAG_SIZE = 10;

int GLOBAL_CLOCK = 0;

struct Memory {
	void read() {
		GLOBAL_CLOCK++; // такт, чтобы получить адрес и саму команду, и начать что - то делать
		GLOBAL_CLOCK += 100; // какие-то действия в памяти
		GLOBAL_CLOCK += (CACHE_LINE_SIZE * 8) / 16; // ответ
		// ответ занимает количество тактов, равное количеству битов в линии, делённому на 16 (т.к. шина шириной 16 бит)
	}

	void write() {
		GLOBAL_CLOCK++; // такт, чтобы получить первую порцию данных и саму команду, и начать что-то делать
		GLOBAL_CLOCK += 100; // какие-то действия в памяти
		GLOBAL_CLOCK++; // такт на ответ
	}
};

struct CacheAddress {
	int tag, set;

	CacheAddress(int tag, int set): tag(tag), set(set) {}
	CacheAddress(int address) {
		tag = address >> (CACHE_OFFSET_SIZE + CACHE_SET_SIZE);
		set = (address >> CACHE_OFFSET_SIZE) % (1 << CACHE_SET_SIZE);
	}
};

struct CacheLine {
	int valid, dirty, tag;

	CacheLine() {
		reset();
	}

	void reset() {
		valid = 0;
		dirty = 0;
		tag = 0;
	}
};

struct CacheSet {
	vector <CacheLine> lines;
	vector <int> lru;

	CacheSet() {
		lines.assign(CACHE_WAY, CacheLine());
		lru.assign(CACHE_WAY, 1);
		reset();
	}

	void reset() {
		for (int i = 0; i < lines.size(); ++i) {
			lines[i].reset();
			lru[i] = 1;
		}
	}

	int get_lru_id() {
		if (lru[0] > lru[1]) {
			return 0;
		}
		return 1;
	}

	void update_lru(int id) {
		lru[id] = 0;
		lru[(id + 1) % 2] = 1;
	}
};

class Cache {
private:
	vector <CacheSet> sets;
	Memory memory;

    // эта функция возвращает номер "пустой" линии, в которую можно записать линию из памяти
	int get_empty_line(int set_id) {
		CacheSet& set = sets[set_id];
		for (int i = 0; i < set.lines.size(); ++i) {
			if (!set.lines[i].valid) {
                // есть невалидная строчка, значит можно вернуть её
				return i;
			}
		}

        // берём самую старую строку и, если она грязная, то записываем информацию из неё в память
		int lru_line_id = set.get_lru_id();
		CacheLine& line = set.lines[lru_line_id];
		if (line.dirty) {
			memory.write();
			line.dirty = 0;
		}

		return lru_line_id;
	}

public:
	Cache() {
		sets.assign(CACHE_SETS_COUNT, CacheSet());
		reset();
	}

	void reset() {
		for (int i = 0; i < sets.size(); ++i) {
			sets[i].reset();
		}
	}

	bool invalidate_line(CacheAddress address) {
		GLOBAL_CLOCK++; // получаем первый такт команды, чтоб начать что-то делать

		for (int i = 0; i < sets[address.set].lines.size(); ++i) {
			CacheLine& line = sets[address.set].lines[i];
			if (line.tag == address.tag && line.valid == 1) {
				// кеш-попадание, добавляем к общему количеству 6 тактов отклика
				GLOBAL_CLOCK += 6;
                
                // если линия грязная, то её надо записать
				if (line.dirty == 1) {
					memory.write();
				}

                // инвалидируем
				line.valid = 0;
				return true;
			}
		}

		// кеш-промах, линии, содержащей такой адрес и нет в кеше
		GLOBAL_CLOCK += 4;
		return false;
	}

	bool read(CacheAddress address, int size) {
		GLOBAL_CLOCK++; // получаем первый такт команды, чтоб начать что-то делать

		bool cache_hit = false;

		for (int i = 0; i < sets[address.set].lines.size(); ++i) {
			CacheLine& line = sets[address.set].lines[i];
			if (line.tag == address.tag && line.valid == 1) {
				// кеш-попадание, добавляем к общему количеству 6 тактов отклика
				cache_hit = true;
				GLOBAL_CLOCK += 6;

                // обновляем массив старости
				sets[address.set].update_lru(i);
			}
		}

		if (!cache_hit) {
            // кеш-промах

            // получаем линию, в которую запишем нужную нам из памяти
			int line_id = get_empty_line(address.set);
			CacheLine& line = sets[address.set].lines[line_id];

			// идём в память 
			GLOBAL_CLOCK += 4;
			memory.read();

            // линия теперь валидная и не грязная, т.к. мы её только что считали
			line.valid = 1;
			line.dirty = 0;

            // присваиваем линии соответствующий тег и обновляем массив последнего использования
			line.tag = address.tag;
			sets[address.set].update_lru(line_id);
		}

		GLOBAL_CLOCK += max(size / 16, 1); // передача данных по 16 бит за такт

		return cache_hit;
	}

	bool write(CacheAddress address, int size) {
		GLOBAL_CLOCK++; // получаем первый такт команды, чтоб начать что-то делать

		bool cache_hit = false;

		for (int i = 0; i < sets[address.set].lines.size(); ++i) {
			CacheLine& line = sets[address.set].lines[i];
			if (line.tag == address.tag && line.valid == 1) {
				// кеш-попадание, добавляем к общему количеству 6 тактов отклика
				cache_hit = true;
				GLOBAL_CLOCK += 6;

                // линия теперь грязная, т.к. мы только что записали в неё новую информацию
				line.dirty = 1;

                // обновляем массив последнего использования
				sets[address.set].update_lru(i);
			}
		}

		if (!cache_hit) {
			int line_id = get_empty_line(address.set);
			CacheLine& line = sets[address.set].lines[line_id];

			GLOBAL_CLOCK += 4;
			memory.read();

            // линия теперь грязная, т.к. мы только что записали в неё новую информацию
			line.dirty = 1;
			line.valid = 1;

            // присваиваем нужный тэг и обновляем массив последнего использования
			line.tag = address.tag;
			sets[address.set].update_lru(line_id);
		}

		GLOBAL_CLOCK++; // ответ

		return cache_hit;
	}
};

int main() {
	Cache cache;
	cache.reset();

	const int M = 64;
	const int N = 60;
	const int K = 32;

	const int A_SIZE = M * K;
	const int B_SIZE = K * N * 2;
	const int C_SIZE = M * N * 4;

	GLOBAL_CLOCK = 0;

	int cache_calls = 0;
	int cache_hits = 0;

	int pa = 0;
	GLOBAL_CLOCK++; // инициализация переменной

	int pc = A_SIZE + B_SIZE;
	GLOBAL_CLOCK++; // инициализация переменной

	for (int y = 0; y < M; y++) {
		GLOBAL_CLOCK++; // переход на новую итерацию цикла (а на первой итерации инициализация переменной y)

		for (int x = 0; x < N; x++) {
			GLOBAL_CLOCK++; // переход на новую итерацию цикла (а на первой итерации инициализация переменной x)

			int pb = A_SIZE;
			GLOBAL_CLOCK++; // инициализация переменной

			int s = 0;
			GLOBAL_CLOCK++; // инициализация переменной

			for (int k = 0; k < K; k++) {
				GLOBAL_CLOCK++; // переход на новую итерацию цикла (а на первой итерации инициализация переменной k) 

				int cache_hit_pa = cache.read(CacheAddress(pa + k), 8);
				int cache_hit_pb = cache.read(CacheAddress(pb + 2 * x), 16);
				cache_calls += 2;
				cache_hits += cache_hit_pa + cache_hit_pb;

				//s += pa[k] * pb[x];
				GLOBAL_CLOCK += 6; // сложение и умножение

				pb += 2 * N;
				GLOBAL_CLOCK++; // сложение
			}
			//pc[x] = s;
			int cache_hit_pc = cache.write(CacheAddress(pc + 4 * x), 32);
			cache_calls++;
			cache_hits += cache_hit_pc;
		}
		pa += K;
		GLOBAL_CLOCK++; // сложение

		pc += 4 * N;
		GLOBAL_CLOCK++; // сложение
	}

	cout << "Cache hit percentage: " << cache_hits << '/' << cache_calls << ' ' << (double)cache_hits / (double)cache_calls * 100 << ' ' << endl;
	cout << "Total clock count: " << GLOBAL_CLOCK;
}