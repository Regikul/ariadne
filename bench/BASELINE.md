# Baseline of the runtimes, 2026-09-16

The first characterization of `ari_concurrent_runtime` against
`ari_single_runtime`, taken with `ari_single_runtime_bench` and
`ari_concurrent_runtime_bench` at commit `607dc2c` plus the concurrent
bench. Nothing here is a budget: the numbers are the reference the next
change is compared against on the same loads.

## Environment

- Intel Core i7-12700H: 6 performance cores and 8 efficient cores, 20
  threads; WSL2 given 16 of them, 8 GB of memory.
- Erlang/OTP 27.2, 16 schedulers online.
- Every row is 5 runs; `run ms` is the median, `min..max` the spread.
  The concurrent bench starts a fresh branch per run and times the
  interval from the first push to the last item at the subscriber.

```
rebar3 as bench shell
> ari_single_runtime_bench:run().
> ari_concurrent_runtime_bench:run().
> ari_concurrent_runtime_bench:scaling().
```

`scaling/0` was cut short at `epochs {1000,100}`: 53 s per run at 4
workers and doubling with every doubling of workers. The rows of
`epochs` over the workers below are for `{100,100}` instead.

## Single runtime

```
shape      params              steps       run ms    min..max ms  us/step  pushed KB     ran KB    peak KB
pipeline   {1,1000}             1000          0.6       0.5..0.8     0.58         48         64        256
pipeline   {1,10000}           10000          3.8       3.7..4.3     0.38        469        626       1760
pipeline   {1,100000}         100000         42.9     39.8..63.6     0.43       4688       6251      20003
pipeline   {4,1000}             4000          2.1       1.9..2.8     0.52         52         75        415
pipeline   {4,10000}           40000         17.6     16.8..18.7     0.44        474        637       3072
pipeline   {4,100000}         400000        188.9   188.6..209.2     0.47       4692       6262      40087
pipeline   {16,1000}           16000          7.7       7.3..8.8     0.48        104        223       1088
pipeline   {16,10000}         160000         75.9     74.5..76.9     0.47        526        786       4608
pipeline   {16,100000}       1600000        848.6   842.0..864.6     0.53       4744       6411      34491
epochs     {10,100}             1010          0.5       0.5..0.6     0.52         48          2        277
epochs     {30,100}             3030          2.1       1.9..2.2     0.68        144          3        448
epochs     {100,100}           10100          6.9       6.5..7.8     0.69        479          8       1760
epochs     {300,100}           30300         28.6     25.6..29.6     0.94       1437         20       7457
epochs     {1000,100}         101000        191.3   189.2..195.5     1.89       4788         64      20003
loop       {10,100}             1100          0.7       0.6..0.9     0.63          6          9         85
loop       {100,100}           10100          5.9       5.7..6.7     0.58          6          9        105
loop       {1000,100}         100100         62.1     60.6..65.4     0.62          6          9        105
```

## Concurrent runtime on one worker

The price of the coordination: the same loads, one worker.

```
shape     params               W     steps    run ms    min..max ms us/step coord% mailbox   wrk KB coord KB  busy
pipeline  {1,1000}             1      1000       1.5       1.3..2.1    1.47   26.5       0      415      362   1.3
pipeline  {1,10000}            1     10000      11.3     10.5..12.4    1.13   26.4       0     2123     1899   1.1
pipeline  {1,100000}           1    100000     111.1   106.8..118.2    1.11   26.3       0    21918    14317   0.8
pipeline  {4,1000}             1      4000       3.8       3.0..4.1    0.95   23.0       0     1173     1536   1.3
pipeline  {4,10000}            1     40000      22.2     21.1..23.7    0.55   22.9       0     4608     2123   1.2
pipeline  {4,100000}           1    400000     248.2   239.7..252.5    0.62   23.2       0    23454    14317   1.0
pipeline  {16,1000}            1     16000      11.3      9.7..12.4    0.71   21.4       0     1173     1536   1.2
pipeline  {16,10000}           1    160000      89.1     86.5..92.3    0.56   21.7       0     4608     3072   1.2
pipeline  {16,100000}          1   1600000     868.6   857.7..896.2    0.54   22.2       0    23454    14317   1.0
exchange  {1,1000}             1      1000       1.3       1.1..1.3    1.26   26.5       0      415      362   0.8
exchange  {1,10000}            1     10000       9.1      8.8..10.7    0.91   26.4       0     2123     1899   1.2
exchange  {1,100000}           1    100000      98.7    93.6..106.0    0.99   26.3       0    21918    14317   0.9
exchange  {4,1000}             1      4000       2.9       2.6..3.2    0.72   22.3       0     1173     1536   1.2
exchange  {4,10000}            1     40000      22.6     21.6..23.6    0.57   22.2       0     4608     2123   1.2
exchange  {4,100000}           1    400000     237.0   236.2..249.8    0.59   22.6       0    23454    14317   1.0
exchange  {16,1000}            1     16000      11.1      9.7..12.5    0.69   20.6       0     1173     1536   1.2
exchange  {16,10000}           1    160000      99.8     88.7..113.7    0.62   20.8       0     4971     3072   1.2
exchange  {16,100000}          1   1600000     922.6   911.1..932.6    0.58   21.5       0    23454    14317   1.0
epochs    {10,100}             1      1010       1.1       0.8..2.5    1.07   39.7       0      138       85   1.6
epochs    {30,100}             1      3030       3.1       2.9..4.1    1.03   56.3       0      191      191   1.7
epochs    {100,100}            1     10100      29.6     29.1..44.1    2.93   90.3       0      191      415   1.3
epochs    {300,100}            1     30300     474.2   466.7..478.5   15.65   98.6       0      277      725   1.1
epochs    {1000,100}           1    101000   14113.0 14025.3..14215  139.73   99.9       2      672     1899   1.0
stream    {100,100,100}        1     10100       9.4      7.2..14.0    0.93   34.7       0      138      224   1.2
stream    {100,100,1000}       1     10100      11.9     11.4..14.5    1.18   63.6       0      191      277   1.8
stream    {1000,100,100}       1    101000     107.8    75.3..126.6    1.07   34.6       0      138      224   1.2
stream    {1000,100,1000}      1    101000     121.3   116.0..123.8    1.20   66.9       0      277      309   1.9
loop      {10,100}             1      1100       1.2       0.9..2.2    1.09   25.0       0      448      672   1.0
loop      {100,100}            1     10100       6.1       5.4..6.4    0.60   20.6       0     1173     1909   1.4
loop      {1000,100}           1    100100      52.3     50.7..58.0    0.52   20.2       0     1173     1909   1.5
```

## Concurrent runtime over the workers

```
shape     params               W     steps    run ms    min..max ms us/step coord% mailbox   wrk KB coord KB  busy
pipeline  {4,100000}           1    400000     239.0   231.0..254.3    0.60   23.2       0    23454    14317   1.0
pipeline  {4,100000}           2    400000     150.4   141.1..154.0    0.38   23.1       0    11857    14317   1.7
pipeline  {4,100000}           4    400000     104.4    94.9..106.4    0.26   20.0     145     8044    72590   3.5
pipeline  {4,100000}           8    400000      98.6    93.0..284.8    0.25   14.6     261     3072    78817   6.5
pipeline  {4,100000}          16    400000     112.7   99.7..1269.2    0.28   10.5     345     3072   155339   9.8
pipeline  {4,100000}          32    400000     436.5   74.3..1885.9    1.09   21.6     412     1899   167114  11.9
exchange  {4,100000}           1    400000     243.1   230.6..252.7    0.61   22.6       0    23454    14317   1.0
exchange  {4,100000}           2    400000     154.7   144.0..159.3    0.39   22.3       0    18679    14317   1.8
exchange  {4,100000}           4    400000     116.5   110.8..125.5    0.29   19.5      81    10295    44499   3.2
exchange  {4,100000}           8    400000      95.0     89.1..98.6    0.24   12.7     654     9345   137890   5.5
exchange  {4,100000}          16    400000      91.8     83.3..1816.9    0.23   10.4    1653     7457   153238   9.9
exchange  {4,100000}          32    400000    1528.6  514.5..2093.3    3.82   21.7    3069     4608   139262  15.0
epochs    {100,100}            1     10100      30.9     29.6..31.7    3.06   90.7       0      277      415   1.3
epochs    {100,100}            2     10200      56.1     53.7..59.5    5.50   94.8       0      138      448   1.2
epochs    {100,100}            4     10400     103.7    94.8..110.9    9.97   97.1       0      138      415   1.2
epochs    {100,100}            8     10800     182.7   179.8..192.0   16.91   98.3       0      138      448   1.2
epochs    {100,100}           16     11600     367.6   347.2..378.2   31.69   99.0       0      138      448   1.1
epochs    {100,100}           32     13200     686.0   680.0..689.0   51.97   99.3       0      105      672   1.1
epochs    {1000,100}           1    101000   13854.0 13569.7..14350  137.17   99.9       2      672     1899   1.0
epochs    {1000,100}           2    102000   26747.0 26685.3..27039  262.23   99.9       0      672     1899   1.0
epochs    {1000,100}           4    104000   53254.0 52894.5..54151  512.06  100.0       0      672     2848   1.0
stream    {1000,100,1000}      1    101000     127.1   119.6..131.5    1.26   68.0       0      277      501   1.9
stream    {1000,100,1000}      2    102000      67.9     65.2..68.6    0.67   49.2       0      138      309   2.2
stream    {1000,100,1000}      4    104000      66.6     63.8..69.1    0.64   42.0       0      105      277   2.6
stream    {1000,100,1000}      8    108000      76.6     70.8..79.0    0.71   40.4       0       65      277   2.8
stream    {1000,100,1000}     16    116000      94.2     87.7..102.4    0.81   40.4       0       40      191   3.1
stream    {1000,100,1000}     32    132000     138.0   132.2..143.1    1.05   42.2       0       40      224   3.6
loop      {1000,100}           1    100100      53.5     51.8..58.5    0.53   20.2       0     1173     1909   1.5
loop      {1000,100}           2    100100      36.8     33.7..38.2    0.37   14.1      50      277    26085   2.9
loop      {1000,100}           4    100100      19.1     17.5..21.6    0.19    5.5      87      448    27948   4.5
loop      {1000,100}           8    100100      14.8     14.3..16.5    0.15    3.8      99      448    38036   6.0
loop      {1000,100}          16    100100      12.7     10.9..15.5    0.13    1.3     110      448    52524   9.4
loop      {1000,100}          32    100100      13.0     11.1..14.6    0.13    5.4     130      448    41478   3.6
```

## What the numbers say

Sound:

- The coordination costs 15–25 % over the single runtime on the large
  loads (`pipeline`, `exchange`: 0.54–0.62 against 0.43–0.53 µs/step),
  and `loop` comes out faster than single (0.52 against 0.62). A round
  of 1000 steps reported as one delta keeps the coordinator at 20–26 %
  of the reductions.
- Handing a message to another worker is nearly free: `exchange` runs
  level with `pipeline` at every number of workers.
- The limit on the messages on their way holds the memory: `stream`
  keeps a worker in 40–277 KB and the coordinator in 191–501 KB over
  100 000 messages and 1000 epochs, whatever the number of workers.
- `loop` scales best, 4.2× at 16 workers, the coordinator down to 1.3 %
  of the reductions.

To improve:

1. **Notifications of open epochs -- optimize.** `epochs` grows about
   as E² on one worker (E=100: 2.9 µs/step; 300: 15.7; 1000: 139.7 --
   14 s for what single does in 0.19 s) and linearly with the workers
   (E=100: 3.1 µs/step at 1 worker, 52.0 at 32). `dispatch` in
   `ari_crt_coordinator` walks every notification asked for on every
   delta, and `ari_progress:complete` walks every pending pointstamp for
   each of them; both grow with E · W while the epochs stay open.
   `stream`, closing every epoch as it goes, runs at 1.1–1.3 µs/step on
   the same E · M, so it is the open epochs alone. A producer closing
   epochs late -- after an acknowledgement, as a producer usually does
   -- meets this at once.

2. **Plateau past 8 workers -- defer until profiled.** `pipeline
   {4,100000}` goes 239 → 150 → 104 → 98 ms over 1, 2, 4, 8 workers
   and stays there; the coordinator falls to 10 % of the reductions, so
   the ceiling is elsewhere: the one push spreading 100 000 items from
   one process, the one subscriber taking 100 000 items, and, on this
   machine, the ninth worker onwards landing on efficient cores and
   hyperthreads. At 16 and 32 workers single runs take 1.3–1.9 s against
   a median of 0.1 s; whether that is a collection of the coordinator's
   heap or the schedulers is to be found with
   `profile({pipeline, {4, 100000}}, 16)` and a look at the spread.

3. **The coordinator's heap at 4 workers and more -- defer until
   profiled.** 72–167 MB on `pipeline {4,100000}` against 14 MB at 1–2
   workers, and 26–52 MB on `loop {1000,100}` where 100 items enter. The
   coordinator keeps counts, yet outgrows the workers several times
   over. The suspects are the push cut into a list per worker and the
   deltas of a loop, 1000 pointstamps each, piling up as garbage while
   the coordinator is too busy to collect. Memory only; the time is
   not affected.

4. **Small pushes -- watch.** A push of 1000 items runs at 1.1–1.5
   µs/step, 2–3× the single runtime: the fixed cost of a round on a
   short load. `stream` with pushes of 100 items and a close each is
   bounded by the round trips of the producer: 66 ms for 1000 pushes
   and 1000 closes at 2 workers and more, about 33 µs a pair, whatever
   the workers do. A service fed in small pushes by one producer is
   bounded by that producer, not by the graph.

## After 1: the frontier and the walk of the notifications

`ari_progress` keeps the frontier of every location -- the outstanding
times no other outstanding time of the location precedes -- and tells
completeness by the frontiers alone; the times of a location are kept
in an ordered set, so that outside of every loop the frontier after a
release is the smallest time left. The notifications asked for live in
`ari_asked`, a tree per vertex walked from the earliest time: a time
found incomplete blocks the times it precedes, and outside of every
loop ends the walk of the vertex. The coordinator delivers all the
notifications due at once; the single runtime takes the earliest.

The same loads, one worker:

```
shape     params               W     steps    run ms    min..max ms us/step coord% mailbox   wrk KB coord KB  busy
epochs    {1000,100}           1    101000      79.5     77.1..95.7    0.79   30.7       0     7457     1173   1.7
epochs    {3000,100}           1    303000     288.0   284.9..291.8    0.95   29.8       0    10907     4608   1.4
pipeline  {4,100000}           1    400000     251.5   237.5..277.2    0.63   19.5       0    23454    20216   0.8
stream    {1000,100,1000}      1    101000      89.3     87.3..96.9    0.88   31.2       0      725     1760   1.7
loop      {1000,100}           1    100100      56.3     53.3..59.3    0.56   18.1       0     1173     3072   1.4
epochs    {1000,100}          16    116000     138.9   129.2..142.3    1.20   40.1       0     1088     1778   2.6
```

and the single runtime:

```
shape      params              steps       run ms    min..max ms  us/step  pushed KB     ran KB    peak KB
epochs     {100,100}           10100          7.3       6.7..8.2     0.73        483          8       2848
epochs     {300,100}           30300         22.3     21.9..25.0     0.73       1446         20       7457
epochs     {1000,100}         101000         89.3     86.1..90.6     0.88       4819         64      20003
epochs     {3000,100}         303000        287.8   283.8..300.3     0.95      14454        189      56489
pipeline   {4,100000}         400000        193.7   179.1..198.0     0.48       4692       6262      40087
loop       {1000,100}         100100         59.6     58.5..60.6     0.60          6         10        105
```

`epochs {1000,100}` went from 14 113 to 80 ms on one worker of the
concurrent runtime and from 191 to 89 ms on the single one; at 3000
epochs both run at 0.95 µs/step, against 0.73 at 100: the growth with
the open epochs is gone. What is left over the workers -- 80 to 139 ms
from 1 to 16 -- is a delta per feed with E · W feeds, and a push of 100
items spread over 16 workers feeds 6 items at a time. `pipeline`,
`stream` and `loop` are unchanged within the spread on both runtimes.

An ordered tree in place of the map of counts was tried first and cost
the single runtime 15 % on `pipeline` and 25 % on `loop`, two tree
operations per message; the counts stayed in a flat map, and the
ordered set of times of a location is touched only when a time
appears at the location or leaves it.
