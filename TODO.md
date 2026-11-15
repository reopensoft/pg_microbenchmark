<div align="center">

# TODO

**Czego benchmark jeszcze nie mierzy — i co już mierzy częściowo.**

Stan na 2026-11-15 · katalog: ponad 2000 testów w 15 tematach

</div>

---

## Legenda

| Status | Znaczenie |
|:---:|---|
| ✅ | zrobione — osobne testy pokrywają obszar |
| 🟡 | częściowo — obszar jest dotknięty w innym temacie (zwykle `cte`), brakuje testów dedykowanych |
| ⬜ | brak |

| Priorytet | Znaczenie |
|:---:|---|
| **P1** | częste w patchach albo duży wpływ na wynik |
| **P2** | ważne |
| **P3** | dodatkowe |

Nowy temat to: plik w `topics/`, wiersz `\ir` w `bench.sql` i wiersz w tabeli
*Test catalog* w `README.md`. Po zrobieniu zmień status w tabeli poniżej.

## Postęp

| Sekcja | ✅ | 🟡 | ⬜ |
|---|:---:|:---:|:---:|
| [1. Typy danych i operatory](#1-typy-danych-i-operatory) | 1 | 1 | 10 |
| [2. Indeksy](#2-indeksy) | 0 | 3 | 2 |
| [3. Mechanizmy zapytań](#3-mechanizmy-zapytań) | 1 | 7 | 7 |
| [4. Serwer i maintenance](#4-serwer-i-maintenance) | 0 | 3 | 5 |
| [5. Konkurencja i transakcje](#5-konkurencja-i-transakcje) | 0 | 2 | 3 |
| [6. Bezpieczeństwo](#6-bezpieczeństwo) | 0 | 3 | 0 |
| [7. CTE — dalsze obszary](#7-cte--dalsze-obszary) | 0 | 4 | 6 |
| [8. Infrastruktura benchmarku](#8-infrastruktura-benchmarku) | 0 | 1 | 8 |
| [9. Repozytorium](#9-repozytorium) | 1 | 0 | 3 |

> [!TIP]
> Najwięcej za najmniej: pozycje **P1** ze statusem 🟡. Dane, tabele i
> pomiary już istnieją; brakuje tylko pliku z testami poza kontekstem CTE.

---

## 1. Typy danych i operatory

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| ✅ | — | Tablice `integer[]` i intarray | tematy `array` (303 testy) i `index`, tabela `g_intarr`, `query_int`, klasy operatorów GIN/GiST | — |
| ⬜ | **P1** | JSONB | tylko `jsonb_agg` w `distinct`/`sort` oraz dokumenty przechodzące przez CTE (`cte.edge_content_jsonb_*`) | `jsonb_set`/`jsonb_insert`/usuwanie, `@>` `<@` `?`, `jsonb_array_elements`, `jsonb_object_keys`, zagnieżdżenia, duże dokumenty, GIN (`jsonb_ops`, `jsonb_path_ops`), `jsonpath` |
| ⬜ | **P1** | Full-text search | — | `to_tsvector`/`to_tsquery`/`websearch_to_tsquery`, `ts_rank`, `ts_headline`, GIN i GiST na `tsvector` |
| ⬜ | **P2** | Typy zakresowe | — | `int4range`/`tsrange`/`numrange`, multirange, `@>` `<@` `&&` `-\|-`, GiST i SP-GiST, ograniczenia `EXCLUDE` |
| ⬜ | **P2** | Typy geometryczne | — | `point`/`box`/`polygon`/`circle`, operatory, GiST, k-NN (`<->`) |
| ⬜ | **P2** | UUID | — | generowanie (`uuidv4`, `uuidv7`), indeks na losowym i na rosnącym kluczu, złączenia |
| 🟡 | **P3** | Interval i czas | kolumny `timestamptz`, kilka testów z `interval` | arytmetyka, `date_trunc`/`date_bin`, zapytania zakresowe po czasie, strefy czasowe |
| ⬜ | **P3** | Bytea | — | duże wartości, funkcje, TOAST |
| ⬜ | **P3** | Inet / CIDR | — | zawieranie, indeks GiST/SP-GiST |
| ⬜ | **P3** | XML | — | parsowanie, `xpath`, `xmltable` |
| ⬜ | **P3** | Hstore | — | operatory, indeks (rozszerzenie, opcjonalne jak intarray) |
| ⬜ | **P3** | Bit string, Money | — | operacje podstawowe |

## 2. Indeksy

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P1** | Index-only scan | indeks z `INCLUDE`, pojedyncze testy w `index` i `cte_scan` | dedykowane: mapa widoczności świeża i nieświeża, heap fetches po zapisach, szerokość indeksu, IOS na GiST/SP-GiST |
| 🟡 | **P1** | Bitmap scan | bitmap AND/OR w `index`, bitmap dokładny i stratny w `index.intarray_bitmap_*` (tylko z `intarray=1`) | stratny bitmap na zwykłym btree, `effective_io_concurrency`, próg przejścia index scan → bitmap → seq scan |
| 🟡 | **P3** | BRIN | jeden indeks i trzy testy | `pages_per_range`, klasy `minmax_multi` i `bloom`, dane słabo skorelowane |
| ⬜ | **P2** | `CREATE INDEX CONCURRENTLY` | — | czas budowy przy obciążeniu zapisem, wpływ na równoległe transakcje, `REINDEX CONCURRENTLY` |
| ⬜ | **P2** | GIN na JSONB i `tsvector` | — | zależy od sekcji 1; także `fastupdate` i lista oczekujących |

## 3. Mechanizmy zapytań

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| ✅ | **P3** | Protokół simple / extended / prepared | zmienna `protocol` dla przebiegu i `protocol => ...` dla testu | — |
| 🟡 | **P1** | Prepared statements, cache planów | `cte_plancache.sql` (35 testów): generic kontra custom, `plan_cache_mode`, parametr skośny, funkcje PL/pgSQL i SQL | to samo bez CTE; unieważnienie przez DDL i zmianę `search_path`; jawne `PREPARE`/`EXECUTE`; test unieważnienia przez `ANALYZE` nie rozróżnia przypadków (koszt `ANALYZE` przykrywa koszt planowania) |
| 🟡 | **P1** | Parallel query | `cte_parallel.sql` (47), temat `pcte` (77), `seqscan` serial kontra parallel | temat dedykowany bez CTE: skalowanie z liczbą workerów na dużych danych, parallel index-only, wyczerpanie `max_parallel_workers` przy wielu sesjach |
| 🟡 | **P1** | `work_mem` i pliki tymczasowe | `cte_memory.sql` (36), zrzut sortowania w `sort`, pomiar plików tymczasowych i WAL dla każdego testu | hash join i hash aggregate poza CTE, `hash_mem_multiplier`, próg przejścia na dysk wyznaczany automatycznie |
| 🟡 | **P2** | Widoki zmaterializowane | `mv_entity_totals` w `cte_alternatives.sql`: odczyt, `REFRESH`, `REFRESH CONCURRENTLY` | koszt odświeżania w funkcji rozmiaru, blokady podczas odświeżania |
| 🟡 | **P2** | Partycjonowanie | `g_part` (16 partycji zakresowych), przycinanie przez CTE, przenoszenie wierszy, Parallel Append, agregacja po partycjach | temat dedykowany: setki i tysiące partycji, przycinanie w czasie wykonania, partycje hash i list, `ATTACH`/`DETACH`, partitionwise join |
| 🟡 | **P2** | Triggery | `cte.dml_trigger_*` (5 testów): BEFORE i AFTER na wiersz | triggery na instrukcję, tabele przejściowe, `WHEN`, triggery odroczone, kaskady |
| 🟡 | **P3** | Kursory | `cte.partial_cursor_*`: `FETCH` porcjami, `MOVE`, `SCROLL`, `WITH HOLD` | kursory poza CTE, kursory w PL/pgSQL |
| ⬜ | **P2** | JIT | — | próg kosztu, JIT kontra bez JIT dla wyrażeń i deformacji krotek, koszt kompilacji przy krótkich zapytaniach |
| ⬜ | **P3** | Savepoints | — | koszt podtransakcji, wiele savepointów, przepełnienie pamięci podręcznej podtransakcji |
| ⬜ | **P3** | Advisory locks | — | `pg_advisory_lock`, `pg_advisory_xact_lock`, rywalizacja |
| ⬜ | **P3** | Dziedziczenie | — | zapytania po hierarchii, porównanie z partycjonowaniem |
| ⬜ | **P3** | Reguły | — | przepisywanie zapytań, reguły `INSTEAD` |
| ⬜ | **P3** | Foreign data wrappers | — | `postgres_fdw`: wypychanie filtrów, złączeń i agregacji; wymaga drugiej bazy |
| ⬜ | **P3** | Inne rozszerzenia | intarray jako wzorzec opcji włączanej świadomie | `pg_trgm`, `btree_gin`, `btree_gist`, `hstore` |

## 4. Serwer i maintenance

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P1** | WAL, `fsync`, `synchronous_commit` | wolumen WAL dla każdego kroku DDL i każdego testu; `-v gucs=...` pozwala porównać dwa ustawienia | testy dedykowane: commit pojedynczy i grupowy, `wal_compression`, `full_page_writes`, tabele `UNLOGGED` |
| 🟡 | **P1** | TOAST | pojedyncze testy w `seqscan`, `array`, `resultsize`, `cte_memory` | temat dedykowany: `pglz` kontra `lz4`, strategie przechowywania, częściowy odczyt (`substr`), aktualizacja kolumn obok dużej wartości |
| 🟡 | **P2** | `VACUUM` / `ANALYZE` / `REINDEX` | czas `VACUUM ANALYZE` w fazie DDL | zapytania przed i po `VACUUM`, wpływ rozdęcia tabeli i indeksu, `REINDEX` |
| ⬜ | **P2** | Checkpoint | — | częstotliwość, skoki opóźnień, pełne obrazy stron po checkpoincie |
| ⬜ | **P2** | Autovacuum | — | narzut podczas obciążenia, autovacuum kontra ręczny `VACUUM` |
| ⬜ | **P3** | `shared_buffers` i cache | — | zimny i ciepły cache, dane większe niż pamięć; wymaga restartu serwera, więc poza zasięgiem `gucs` |
| ⬜ | **P3** | Backup, `pg_dump` | — | czas zrzutu i odtworzenia danych benchmarku |
| ⬜ | **P3** | Replikacja logiczna, dekodowanie | — | narzut na zapis, opóźnienie; wymaga repliki |

## 5. Konkurencja i transakcje

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P2** | Poziomy izolacji | `cte.iso_*`: READ COMMITTED, REPEATABLE READ, SERIALIZABLE z ponowieniami | write skew, phantom reads, odsetek ponowień w funkcji liczby klientów |
| 🟡 | **P2** | Blokady wierszy | temat `locking` (14), `cte_lock.sql`, kolejka `SKIP LOCKED` | skalowanie kolejki z liczbą klientów, blokady tabel, `lock_timeout` |
| ⬜ | **P1** | Wykrywanie zakleszczeń | testy celowo ich unikają; pgbench ponawia transakcję | scenariusz z gwarantowanym zakleszczeniem, koszt `deadlock_timeout` |
| ⬜ | **P1** | Ponowne sprawdzanie wierszy przy współbieżnym zapisie | — | `UPDATE` czekający na blokadę, którego warunek przestaje być spełniony; wynik CTE nie jest przeliczany — wymaga sterowania dwiema sesjami (patrz sekcja 8) |
| ⬜ | **P3** | Savepoints, advisory locks | — | patrz sekcja 3 |

## 6. Bezpieczeństwo

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P2** | Row level security | `cte_rls.sql` (18 testów, tylko z `rls_role`), tabela `g_rls`, skrypt `rls_role.sql` | polityki z podzapytaniem, wiele polityk naraz, RLS w złączeniach wielu chronionych tabel |
| 🟡 | **P3** | Role i uprawnienia | `SET LOCAL ROLE` w testach RLS, widoki `security_barrier`, funkcje `SECURITY DEFINER` | koszt sprawdzania uprawnień, uprawnienia kolumnowe, głębokie hierarchie ról |
| 🟡 | **P3** | `search_path` | rozwiązywanie nazw operatorów intarray | długa ścieżka, koszt rozwiązywania nazw funkcji, funkcje z klauzulą `SET search_path` |

## 7. CTE — dalsze obszary

Temat `cte` ma ponad 1300 testów w 27 plikach. Z listy dalszych pomysłów
zrobione są: estymacje, cache planów, pamięć i pliki tymczasowe, rozmiar
problemu złączeń, równoległość i porównanie z alternatywami oraz przypadki
brzegowe. Zostało:

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P1** | Rekurencja od strony zasobów | semantyka w `cte_recursive.sql`, dwa testy pamięci | pamięć tabeli roboczej i deduplikacji w `UNION`, narzut na iterację, algorytmy grafowe (najkrótsza ścieżka, przeszukiwanie dwukierunkowe) |
| 🟡 | **P2** | Partycje i CTE | przycinanie, Parallel Append | przycinanie w czasie wykonania przez CTE, rekurencja po tabeli partycjonowanej |
| 🟡 | **P2** | CTE w obiektach pochodnych | widoki nad `g_events` | CTE w definicji widoku i widoku zmaterializowanego, `CREATE TABLE AS`, `INSERT ... SELECT`, `COPY (zapytanie)` |
| ⬜ | **P2** | Memoize i Material | — | parametryzowany odczyt CTE w pętli zagnieżdżonej: Memoize, Material albo ponowny skan |
| ⬜ | **P2** | JIT a CTE | — | ten sam koszt całkowity rozłożony inaczej przy wbudowaniu i materializacji |
| 🟡 | **P2** | Szerokie wartości inne niż tablice | tablice; JSONB i tekst 10 kB w `cte_edge.sql` (`cte.edge_content_*`) | typy złożone, dokumenty JSONB powyżej progu TOAST, pomiar rozpakowywania w buforze CTE |
| ⬜ | **P3** | Odwołania do całego wiersza | — | `select c from c`, `c.*`, `row_to_json(c)` — blokują przycinanie kolumn |
| ⬜ | **P3** | WAL i replika | WAL na test jest mierzony | jedno polecenie z kilkoma zapisami kontra osobne polecenia; zapisujące CTE na serwerze zapasowym |
| ⬜ | **P3** | Obserwowalność | — | narzut `EXPLAIN (ANALYZE, BUFFERS, WAL)`, `auto_explain`, `pg_stat_statements` |
| ⬜ | **P3** | Anulowanie i błędy zasobów | `statement_timeout` w rekurencji | anulowanie w trakcie materializacji i sortowania, sprzątanie plików |

## 8. Infrastruktura benchmarku

| | Pr. | Temat | Co jest | Czego brakuje |
|:---:|:---:|---|---|---|
| 🟡 | **P2** | Sumy kontrolne między przebiegami | każdy jednozdaniowy test odczytu i testy z `SET LOCAL` | testy z kursorami, blokami `DO` i zapisami |
| ⬜ | **P1** | Scenariusze dwóch sesji o ustalonej kolejności | pgbench daje tylko losowe przeplatanie | sterownik kroków „sesja A, sesja B” — potrzebny do zakleszczeń i ponownego sprawdzania wierszy |
| ⬜ | **P2** | Pomiar zasobów w trybie `mixed` | pliki tymczasowe i WAL tylko w trybie `isolated` | rozbicie na skrypty albo wynik zbiorczy |
| ⬜ | **P2** | Pamięć procesu | pamięć węzłów planu z `EXPLAIN ANALYZE` | szczytowe zużycie pamięci backendu podczas pgbench |
| ⬜ | **P2** | Test `temp_file_limit` | — | ustawienie wymaga superużytkownika, a benchmark ma go nie wymagać |
| ⬜ | **P2** | Liczby testów w README | wpisane ręcznie | generowanie z katalogu albo usunięcie liczb |
| ⬜ | **P3** | Częściowy odczyt na poziomie protokołu | modelowany kursorem | klient inny niż pgbench (`Execute` z limitem wierszy) |
| ⬜ | **P3** | Weryfikacja na większych skalach | wszystko uruchamiane na `data_scale=0.01` i w presecie `sanity` | przebieg na skali 1 i 10: czasy, rozmiary, testy zależne od planu |
| ⬜ | **P3** | Blokada współdzielonej bazy | warunek sprawdzony tylko w pustej bazie | test na bazie z obcymi tabelami |

## 9. Repozytorium

| | Pr. | Temat | Uwagi |
|:---:|:---:|---|---|
| ✅ | **P1** | Pierwszy commit | projekt jest w repozytorium |
| ⬜ | **P1** | Licencja | brak pliku `LICENSE` |
| ⬜ | **P2** | Status skryptów Pythona | `run_bench.py` i `report_html.py` są w katalogu, a README mówi, że benchmark potrzebuje tylko `psql` i `pgbench` — opisać je albo wyłączyć z repozytorium |
| ⬜ | **P3** | CI | jeden przebieg `micro-benchmark` z samymi sprawdzeniami w bazie na PostgreSQL 18 |

---

<details>
<summary><b>Zrobione od powstania tej listy</b></summary>

| Obszar | Gdzie |
|---|---|
| Tablice `integer[]`, intarray, `query_int`, klasy operatorów GIN/GiST | `array_int.sql`, `array_intarray.sql`, `array_queryint.sql`, `index_intarray.sql` |
| Zapisujące CTE, blokady, izolacja, RLS, zakresy nazw | `cte_dml.sql`, `cte_lock.sql`, `cte_txn.sql`, `cte_rls.sql`, `cte_scope.sql` |
| Grafy zależności CTE, niepełny odczyt | `cte_graph.sql`, `cte_partial.sql` |
| Estymacje, cache planów, pamięć, rozmiar złączeń | `cte_estimate.sql`, `cte_plancache.sql`, `cte_memory.sql`, `cte_collapse.sql` |
| Równoległość w CTE, CTE kontra alternatywy | `cte_parallel.sql`, `cte_alternatives.sql` |
| Scenariusze dla równoległego wykonania CTE | `pcte.sql` |
| Ustawienia serwera na przebieg, filtr po identyfikatorze, protokół na test | `-v gucs=...`, `-v only=...`, `protocol => ...` |
| Sumy kontrolne wyników, estymacje i pamięć z `EXPLAIN ANALYZE`, pliki tymczasowe i WAL na test | tagi `checksum`, `analyze`; tabele `explain_stats`, `resource` |
| Raport planów, porównanie dwóch przebiegów | `report/explain.sql`, `report/compare.sql` |
| Preset `sanity`: puste tabele, jedna transakcja na test, tag `needs_data` | `presets/presets.sql` |

</details>
