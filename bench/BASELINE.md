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

## After 2: the deltas of a round summed

A worker used to report a round as two lists of pointstamps, one
entry per message delivered and per message sent -- up to 2000 for a
round of 1000 steps, of which a handful were distinct -- and the
coordinator counted them one by one. Now the worker sums the deltas of
a round into a map of pointstamp to net count (see
`ari_progress:sum/2`), and the coordinator applies the map. The same
loads, one worker, 16 schedulers:

```
shape     params               W     steps    run ms    min..max ms us/step coord% mailbox   wrk KB coord KB  busy
pipeline  {4,100000}           1    400000     215.2   205.8..231.8    0.54    6.3       0    23454    20216   0.8
pipeline  {4,1000}             1      4000       2.9       2.7..4.0    0.72    6.8       0      448      224   1.2
exchange  {4,100000}           1    400000     219.1   213.7..229.9    0.55    6.1       0    23454    20216   0.8
epochs    {1000,100}           1    101000      76.3     73.7..87.3    0.76   26.2       0     7457     1173   1.5
stream    {1000,100,1000}      1    101000      87.4     82.2..95.8    0.87   26.5       0      725     1088   1.5
loop      {1000,100}           1    100100      58.2     56.6..58.7    0.58    0.3       0      191       40   1.1
```

The coordinator's share of the reductions fell from 19.5 to 6.3 % on
`pipeline` and from 18 to 0.3 % on `loop`; `pipeline {4,100000}` on
one worker went from 251 to 215 ms, 0.54 µs/step against 0.48 of the
single runtime. The coordinator's heap on `pipeline` at 4 workers and
more fell from 72–167 MB to 18.7 MB, which is the copy of the push,
and on `loop` from 26–52 MB to 40–107 KB; the worker's heap on `loop`
from 1173 to 191 KB. Item 3 of the baseline is closed by this.

### The schedulers of this machine

With the coordinator out of the way the runs at 12 workers and more
turned bimodal: `exchange {4,100000}` at 16 workers takes either about
100 ms or 0.8–2 s, all 16 schedulers busy throughout, and the same
holds without the watcher of the bench and at a tenth of the load.
Turning the busy waiting of the schedulers off (`+sbwt none`) does
not help; running 8 schedulers (`+S 8`) does:

```
shape     params               W     steps    run ms    min..max ms us/step coord% mailbox   wrk KB coord KB  busy
pipeline  {4,100000}           1    400000     213.6   196.6..222.8    0.53    6.3       0    23454    20216   0.8
pipeline  {4,100000}           2    400000     140.8   136.6..152.0    0.35    6.3       0    11857    18680   1.4
pipeline  {4,100000}           4    400000      97.2     95.3..99.0    0.24    6.2       0     7457    18681   2.7
pipeline  {4,100000}           8    400000      89.7    85.5..499.9    0.22    6.2       1     4971    18680   4.7
pipeline  {4,100000}          16    400000      83.7    81.0..497.5    0.21    6.2       6     2848    18683   4.7
exchange  {4,100000}           1    400000     214.2   202.9..241.0    0.54    6.1       0    23454    20216   0.8
exchange  {4,100000}           2    400000     141.0   136.6..145.7    0.35    6.0       0    13731    18680   1.4
exchange  {4,100000}           4    400000     102.4   100.9..104.9    0.26    6.0       0     9345    18682   2.5
exchange  {4,100000}           8    400000      88.8    76.7..690.1    0.22    6.0       3     8044    18685   4.3
exchange  {4,100000}          16    400000      86.8     83.1..91.3    0.22    6.2       0     4608    18700   4.2
stream    {1000,100,1000}      1    101000      84.7     83.8..86.6    0.84   26.5       0      725     1088   1.5
stream    {1000,100,1000}      2    102000      52.7     50.6..57.5    0.52   28.4       0      725     1173   2.8
stream    {1000,100,1000}      4    104000      74.4     67.5..76.2    0.72   32.9       0      138      277   2.7
stream    {1000,100,1000}      8    108000      77.3     74.6..80.6    0.72   36.8       0       65      139   2.9
stream    {1000,100,1000}     16    116000     104.8    99.4..111.2    0.90   41.4       0       40      138   3.0
```

So the outliers of item 2 are the machine: 16 schedulers on the 16
virtual processors WSL2 has over 6 performance and 8 efficient cores,
and a run is as slow as its slowest worker. The scaling of the runtime
is to be read from the rows with 8 schedulers: `pipeline` and
`exchange` reach 84–87 ms at 8 workers and more, with 4.7 schedulers
busy, which is the serial part -- one push cutting 100 000 items and
one subscriber taking them -- and stays item 3 of the list to look at.

## After 3: the push counted as one and dealt through a tuple

The bench got a column, `fed ms`: the time the producer spent in the
pushes and the closes of the median run. On `pipeline {4,100000}` it
was 30 ms at every number of workers -- the coordinator counting the
100 000 items of the push one by one and dealing them through a map
with a closure per item -- and the workers stood idle for those 30 ms
before the first feed reached them. The push is now counted as one
sum and dealt in turn through a tuple of one list per worker, by key
through a map without closures.

The plateau was looked into first. A probe timed the push, the first
item at the subscriber and the last one, and sampled the subscriber's
mailbox: it peaked at a few thousand of 100 000, so the subscriber
keeps up. A graph ending in a counting vertex, one `done' per worker
instead of 100 000 items, ran 71–82 ms at 8 workers against 86–97 with
the items, so the 100 000 sends to one subscriber cost some 15 ms of
the tail. What remained -- 8 workers taking 40 ms for the 50 000 steps
each that one worker takes 20 ms for -- was checked against 8 single
runtimes run at once in processes of their own, with nothing shared:
19 ms alone, 28–43 ms each when eight run together. The slowdown per
worker is the machine, the cores shared and the clock lower under
load, not the runtime.

8 schedulers, one worker:

```
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
pipeline  {4,1000}             1      4000       2.6       2.3..3.2    0.66     0.2    1.1       0      448      105   1.1
pipeline  {4,100000}           1    400000     191.3   187.9..204.3    0.48     5.0    0.9       0    23454     6508   0.8
exchange  {4,100000}           1    400000     191.4   189.3..196.9    0.48     4.2    0.8       0    23454     6508   0.8
epochs    {1000,100}           1    101000      94.5     75.3..98.7    0.94     9.7   12.7       0     4971     1173   1.2
stream    {1000,100,1000}      1    101000      82.5     81.3..85.2    0.82    78.1   13.2       0      725     1088   1.3
loop      {1000,100}           1    100100      88.6     57.9..89.9    0.89     0.1    0.2       0      191       15   1.1
```

and over the workers:

```
pipeline  {4,100000}           1    400000     204.4   201.6..220.6    0.51     6.8    0.9       0    23454     6508   0.8
pipeline  {4,100000}           2    400000     121.6   116.2..124.9    0.30     5.3    0.9       0    11857     6509   1.6
pipeline  {4,100000}           4    400000      85.6     82.3..92.5    0.21     7.7    0.9       0     7457     6508   3.7
pipeline  {4,100000}           8    400000      74.0     71.0..79.8    0.19     8.8    0.9       0     4971     8044   6.2
pipeline  {4,100000}          16    400000      71.2    68.1..937.8    0.18    12.9    0.9       1     2848     9349   6.3
exchange  {4,100000}           1    400000     190.8   186.9..216.5    0.48     5.4    0.8       0    23454     6508   0.8
exchange  {4,100000}           2    400000     123.7   120.9..129.0    0.31     5.7    0.8       0    15980     6508   1.5
exchange  {4,100000}           4    400000      81.0     79.9..84.6    0.20     6.1    0.9       0     9345     6508   3.1
exchange  {4,100000}           8    400000      66.7    60.8..403.8    0.17     9.0    0.9       7     8993     8044   5.9
exchange  {4,100000}          16    400000      61.3    59.4..298.1    0.15     9.8    1.2       9     4608     9360   6.2
stream    {1000,100,1000}      1    101000      88.8     85.3..93.4    0.88    84.8   13.1       0      725     1088   1.3
stream    {1000,100,1000}      2    102000      53.4     51.0..59.7    0.52    47.8   16.4       0      725     1760   2.4
stream    {1000,100,1000}      4    104000      48.2     45.2..50.9    0.46    38.7   21.6       0      725     1765   3.8
stream    {1000,100,1000}      8    108000      68.8     64.6..70.6    0.64    68.2   29.0       0      105      191   3.4
stream    {1000,100,1000}     16    116000      89.8     88.6..90.7    0.77    89.7   35.7       0      40      138   3.3
epochs    {1000,100}           1    101000      80.1     72.9..85.8    0.79     9.9   12.8       0     7457     1899   1.2
epochs    {1000,100}           2    102000      50.5     45.3..52.3    0.50    11.7   16.0       0     2848     1760   2.3
epochs    {1000,100}           4    104000      43.5     42.7..47.9    0.42    29.3   20.7       0     1088     1764   4.0
epochs    {1000,100}           8    108000      67.0     64.9..68.7    0.62    48.1   27.9       0     1088     1768   3.5
epochs    {1000,100}          16    116000     109.9   105.7..110.7    0.95    79.5   36.2       0     1088     2873   3.1
```

On one worker the concurrent runtime now runs `pipeline {4,100000}` at
0.48 µs/step, as the single runtime does: the coordination costs
nothing measurable on a large push. The push takes 5–13 ms instead of
30, the coordinator's share is 0.9 %, its heap 6.5 MB. `pipeline` and
`exchange` reach 61–74 ms at 8 and 16 workers, 2.9× of one worker on
hardware that gives eight independent processes 1.5–2.2× less each.

Left as they are:

- The tail of 100 000 items sent one by one to one subscriber, some
  15 ms at 8 workers: the per-item message is the API of `subscribe/2`.
- `epochs` and `stream` past 4 workers: `fed ms' grows with the
  workers, 29 → 80 ms from 4 to 16, since every push of 100 items turns
  into W feeds and W deltas the coordinator handles before the next
  push. The price of small pushes, item 4 of the baseline, unchanged.
- `loop` on one worker showed 58–90 ms across runs in this session
  against 56–58 before; the spread is the machine's.

## The quality of the parallelism

Against an ideal with no coordination at all -- W single runtimes run
at once in processes of their own, each on a W-th of the items,
loaded before the clock -- `pipeline {4,100000}` with 8 schedulers:

```
W                       1      2      4      8
independent singles   196    108     53     38   ms, the slowest of W
concurrent runtime    197    114     74     66   ms
gap                     0      6     21     28   ms
```

Of the 28 ms at 8 workers, 9 are the push (the singles are loaded
outside of the clock) and some 15 the 100 000 items sent one by one to
one subscriber (the singles keep theirs in a list); the protocol of
rounds, deltas and notifications is the rest, about 4 ms, in line with
the coordinator's 0.9 % of the reductions. On a large push the
coordination costs nothing to speak of; the serial entry and exit do.

On small pushes the coordination is the cost: a push turns into W
feeds, W deltas, and for an epoch W notifications and W deltas more --
4W messages through the coordinator whatever the number of items. The
same 100 000 items in pushes of 100, 1000 and 10 000:

```
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
epochs    {1000,100}           1    101000      81.5     76.6..87.6    0.81     8.7   12.8       0     8993     1088   1.1
epochs    {100,1000}           1    100100      57.4     54.1..59.4    0.57     4.3    4.2       0     9345      362   1.0
epochs    {10,10000}           1    100010      55.6     54.4..64.5    0.56     5.8    3.7       0    15268     1899   0.9
epochs    {1000,100}           8    108000      75.0     68.3..89.7    0.69    57.1   27.9       0     1088     2862   3.3
epochs    {100,1000}           8    100800      20.9     18.1..21.9    0.21    10.8    7.8       0     1088      501   5.7
epochs    {10,10000}           8    100080      15.1     14.3..15.4    0.15    11.8    4.5       0     1173     3435   6.1
stream    {1000,100,1000}      1    101000      92.0    88.1..105.1    0.91    87.4   13.1       0      725     1088   1.3
stream    {100,1000,10000}     1    100100      75.2     64.2..88.9    0.75    68.2    4.4       0     1899      362   1.1
stream    {10,10000,100000}    1    100010      50.6     40.5..65.2    0.51     5.6    3.8       0    17517     2485   0.9
stream    {1000,100,1000}      8    108000      74.4     73.1..82.1    0.69    74.4   28.4       0      105      138   3.2
stream    {100,1000,10000}     8    100800      22.2     19.4..24.2    0.22    17.4    8.0       0      415      501   5.9
stream    {10,10000,100000}    8    100080      16.1     14.7..18.0    0.16    12.2    4.4       0     1173     3435   6.0
```

At 8 workers a push of 100 items costs 75 µs whatever it carries,
about 9 µs per worker fed; a push of 1000 brings the coordinator down
to 8 % and a push of 10 000 to 4.5 %. The rule of thumb: a push of a
hundred items per worker or more keeps the coordination under a tenth.

A lever exists and is a matter of design, not of tuning: a push
smaller than that could be handed to one worker rather than dealt in
turn over all of them, at 4 messages instead of 4W. It changes what
`push/4` promises about the spread and is not done here.

## Corrections after a review

Three things above were wrong, found by a review of the bench:

1. **`exchange` measured no exchange.** Its edges were all keyed by
   the message itself, so a message hashed to one and the same worker
   at every hop and changed workers once at most. The claim that
   handing a message to another worker is nearly free rested on it
   and is withdrawn. The key now takes the edge in, and a message is
   hashed anew at every hop.
2. **The `mailbox` column sampled nothing.** The watcher sampled on
   the `after` of a `receive` that every trace message restarted, so
   under frequent collections it sampled only at the end. It samples
   on a timer of its own now.
3. **The outliers were the subscriber, not the machine.** Thirty runs
   of `pipeline {4,100000}` on 8 workers, each split into the push,
   the time to the first item at the subscriber, and the tail: the
   push at 6–9 ms and the first item at 25–31 ms in every run, the
   tail from 35 to 637 ms, half the runs slow. The bench's consumer
   kept its mailbox on the heap, and a process a few thousand
   messages behind copies them all at every collection and falls
   further behind. With `message_queue_data` set to `off_heap` the
   thirty runs are 49–78 ms, the tail 17–33; on 16 schedulers 16
   workers run `pipeline` at 47 ms (44.6..57.6) and 32 workers at 41
   ms. The bimodal runs at 16 schedulers and the advice to measure
   with 8 were this and are withdrawn. A subscriber to a fast output
   is to keep its mailbox off the heap.

With the exchange measured, 8 schedulers:

```
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
exchange  {4,100000}           1    400000     200.5   196.1..225.5    0.50     7.2    0.8       1    34491     6508   0.8
exchange  {4,100000}           2    400000     133.5   130.9..155.9    0.33     4.9    0.9       1    21918     6509   1.5
exchange  {4,100000}           4    400000      91.7     90.6..97.1    0.23     5.9    1.7       9     9345     8993   3.4
exchange  {4,100000}           8    400000     111.8    92.4..158.9    0.28     7.2    5.5   13966    11831    17429   6.6
exchange  {4,100000}          16    400000     138.7   114.0..157.8    0.35     7.6    3.4   84147     7462    27862   6.5
```

and on 16 schedulers, the consumer off the heap: 16 workers 121.9 ms
(119.2..216.4) with the coordinator's mailbox at 83 000 and its heap
at 31 MB; 32 workers 457.5 ms (133.1..2796.7), mailbox 147 000, heap
109 MB. `pipeline` at the same points: 47 and 41 ms.

The exchange costs, and the cost grows with the workers: the
coordinator's mailbox tells that the deltas come by the tens of
thousands, one per round, and the rounds have shrunk. A worker runs a
round for every `exchange' it is sent, and once its own feed is
delivered a round is as long as the batch that came in; a batch is a
slice of another worker's outbox cut W − 1 ways, so the batches, and
with them the rounds and the outboxes, shrink down the chain to a
handful of events, each round reporting a delta. This is the runtime,
not the bench, and is the next item.

## After 4: a round takes in what came meanwhile

A worker's round used to close with its queue, so once its own feed
was delivered every batch sent by another worker made a round of its
own, and the batches shrank down the chain. Now, whenever the queue
runs empty within the budget of a round, the worker returns to its
server loop with a timeout of zero, which fires only once the mailbox
is empty: whatever was told meanwhile -- items fed or sent,
notifications -- is taken into the same round, and the round is
closed on the timeout. (A first cut drained the mailbox with a
selective receive inside the round; the loop's timeout does the same
with every message going through the loop, and measured the same.)
16 schedulers, the consumer off the heap:

```
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
exchange  {4,100000}           1    400000     218.2   202.8..226.5    0.55     7.3    0.8       1    23454     6508   0.9
exchange  {4,100000}           2    400000     132.5   129.2..137.0    0.33     4.8    0.8       0    21918     6508   1.7
exchange  {4,100000}           4    400000      90.1     86.9..93.6    0.23     7.2    0.8       0    10295     8993   3.0
exchange  {4,100000}           8    400000      66.3     65.6..70.2    0.17     9.1    0.9       2    10295     6508   6.2
exchange  {4,100000}          16    400000      70.0     68.0..97.3    0.17    13.1    1.0      77     8044     9378  10.0
exchange  {4,100000}          32    400000      69.2     66.6..70.7    0.17    15.5    2.0     279     4971     9518  11.1
pipeline  {4,100000}           1    400000     212.3   199.3..237.0    0.53     5.4    0.9       1    34491     6508   0.9
pipeline  {4,100000}           2    400000     115.0   113.3..121.6    0.29     5.7    0.9       1    11857     6508   1.7
pipeline  {4,100000}           4    400000      65.0     62.9..65.6    0.16     6.9    0.9       2     8044     6508   3.4
pipeline  {4,100000}           8    400000      48.0     47.0..55.0    0.12     7.4    0.9       4     4608     6508   6.2
pipeline  {4,100000}          16    400000      45.7     42.9..59.3    0.11    11.8    0.9       1     1899     9352   9.3
pipeline  {4,100000}          32    400000      46.9     44.2..48.1    0.12    12.1    0.9      23     1088     9352  10.3
epochs    {1000,100}           1    101000      93.6    89.3..100.9    0.93    10.4   11.4       0    17181     1760   1.0
stream    {1000,100,1000}      1    101000      94.9    92.6..111.2    0.94    90.6   11.4       0      810     1088   1.1
loop      {1000,100}           1    100100      65.0     53.4..69.1    0.65     0.1    0.2       1      191       15   1.1
epochs    {1000,100}           8    108000      59.7     56.7..63.7    0.55    41.0   24.4      10     1760     3072   4.1
stream    {1000,100,1000}      8    108000      72.1     66.9..73.8    0.67    70.9   25.8       7      191      418   3.5
loop      {1000,100}           8    100100      21.2     18.7..29.3    0.21     1.2    0.3       2       65       65   6.6
```

`exchange` at 16 workers went from 139 to 70 ms and at 32 from 458 to
69; the coordinator's mailbox from 83 000 and 147 000 to 77 and 279,
its heap from 31 and 109 MB to 9 MB. The exchange now costs some 20
ms over `pipeline` at 8 workers and more, the copying between the
workers. `pipeline` gained too, 63 to 48 ms at 8 workers, as did
`epochs`, 78 to 60: the notifications and the feeds waiting are taken
into one round as well. The single-worker rows are unchanged.

With the subscriber off the heap and the rounds whole, the runtime
uses 16 and 32 workers on 16 schedulers as well as 8: `pipeline` at
46–48 ms from 8 workers on, 4.4× of one worker, against the 5.2× of
eight processes sharing nothing on this machine.
