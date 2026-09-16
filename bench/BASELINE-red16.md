# Baseline on a VPS, 2026-09-16

The same suite as `BASELINE.md` after its item 3, run on a rented
virtual server for numbers free of the laptop's hybrid cores: the
scaling of the runtime against the machine's own, from the same
compiled beams.

## Environment

- h2.nexus RED-16: AMD Ryzen 9 7950X3D, 8 virtual processors shown
  as 8 cores of one thread each, 15 GB, QEMU/KVM; Ubuntu 24.04.5,
  Erlang/OTP 27.3 (esl-erlang), `erl +S 8`.
- `vmstat 5` alongside the whole run: steal 0 throughout, idle 62–87 %.
- The per-step cost is higher than on the laptop's performance cores
  (single `pipeline {4,100000}`: 0.69 µs/step against 0.48), so the
  rows compare within this file, not with `BASELINE.md`.

## The run

```
== independent singles, slowest of N, median of 5
N=1: 244 ms
N=2: 184 ms
N=4: 73 ms
N=8: 41 ms
== single runtime
shape      params              steps       run ms    min..max ms  us/step  pushed KB     ran KB    peak KB
pipeline   {4,100000}         400000        277.2   257.6..326.3     0.69       4692       6262      34491
epochs     {1000,100}         101000        130.0   123.1..143.0     1.29       4819         64      20003
loop       {1000,100}         100100         77.5     73.0..82.7     0.77          6         10        105
== concurrent grid, one worker
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
pipeline  {1,1000}             1      1000       1.0       0.8..1.3    0.97     0.3    3.7       0      224      105   1.1
pipeline  {1,10000}            1     10000       8.1       7.5..9.6    0.81     2.7    3.0       0     2123      949   1.2
pipeline  {1,100000}           1    100000      94.1    80.7..101.6    0.94     6.1    2.7       1    21918    10530   0.8
pipeline  {4,1000}             1      4000       3.1       2.9..3.5    0.76     0.2    1.1       0      448      105   1.1
pipeline  {4,10000}            1     40000      20.2     19.7..22.1    0.51     0.7    1.1       0     4608      725   1.0
pipeline  {4,100000}           1    400000     310.7   270.5..346.7    0.78     5.9    0.9       0    23454     6508   0.7
pipeline  {16,1000}            1     16000      10.1     10.0..11.9    0.63     0.4    0.5       0      672      415   1.1
pipeline  {16,10000}           1    160000     102.6    95.5..106.3    0.64     0.8    0.4       0     3072      949   0.9
pipeline  {16,100000}          1   1600000    1236.2 1060.0..1318.0    0.77     9.0    0.4       0    32005     6508   0.7
exchange  {1,1000}             1      1000       1.1       0.9..1.4    1.06     0.2    3.7       0      224      105   1.1
exchange  {1,10000}            1     10000       7.9       7.7..8.3    0.79     0.6    3.0       0     2123      949   1.0
exchange  {1,100000}           1    100000      90.2    83.9..108.0    0.90     4.8    2.7       1    21918    10530   0.8
exchange  {4,1000}             1      4000       3.7       3.3..3.8    0.93     0.3    1.1       0      448      105   1.2
exchange  {4,10000}            1     40000      25.7     24.6..26.2    0.64     0.7    1.0       0     4608      725   1.0
exchange  {4,100000}           1    400000     342.2   269.6..372.9    0.86     7.5    0.9       1    23454     6508   0.7
exchange  {16,1000}            1     16000      10.6     10.5..11.1    0.66     0.3    0.5       0      672      415   1.1
exchange  {16,10000}           1    160000     110.7   107.5..116.7    0.69     0.8    0.4       0     3072      949   1.0
exchange  {16,100000}          1   1600000    1227.7 1175.1..1256.7    0.77     9.4    0.3       1    23454     6508   0.7
epochs    {10,100}             1      1010       1.0       0.9..1.3    1.03     0.6   11.3       0      138       40   1.3
epochs    {30,100}             1      3030       3.4       3.1..4.6    1.13     0.8   11.9       0      448       40   1.3
epochs    {100,100}            1     10100       9.4      9.3..10.2    0.93     1.6   12.0       0     1173      138   1.2
epochs    {300,100}            1     30300      29.8     24.9..31.1    0.98     4.2   12.2       0     1760      415   1.2
epochs    {1000,100}           1    101000     103.3   100.3..128.1    1.02    12.1   12.8       0     7457     1173   1.2
stream    {100,100,100}        1     10100      12.0      6.7..15.8    1.19    11.9   11.1       0      105       65   1.4
stream    {100,100,1000}       1     10100      11.0      9.7..13.6    1.09     9.2   13.0       0      277      191   1.3
stream    {1000,100,100}       1    101000      94.5    86.7..141.0    0.94    94.4   11.2       0      105      105   1.2
stream    {1000,100,1000}      1    101000     120.8   113.5..129.9    1.20   113.9   13.1       0      725     1088   1.3
loop      {10,100}             1      1100       1.1       1.0..1.1    0.97     0.2    0.8       0      138       12   1.1
loop      {100,100}            1     10100       9.2      9.0..10.0    0.91     0.2    0.3       0      138       15   1.2
loop      {1000,100}           1    100100      79.3     73.6..90.7    0.79     0.2    0.2       0      191       15   1.1
== scaling
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
pipeline  {4,100000}           1    400000     281.2   261.5..315.0    0.70    11.7    0.9       0    23454     6508   0.7
pipeline  {4,100000}           2    400000     162.3   148.8..216.8    0.41     5.3    0.9       0    11857     6508   1.4
pipeline  {4,100000}           4    400000      97.0    90.6..104.7    0.24    10.4    0.9       0     7457     6508   3.5
pipeline  {4,100000}           8    400000      71.1    68.5..274.0    0.18    13.9    0.9       3     4971     8044   5.7
pipeline  {4,100000}          16    400000      60.0     55.4..70.0    0.15    17.0    0.9       0     2848     9350   5.4
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
exchange  {4,100000}           1    400000     304.5   280.6..350.1    0.76     8.5    0.9       1    23454     6508   0.7
exchange  {4,100000}           2    400000     211.2   189.2..233.5    0.53     9.3    0.9       0    15980     6508   1.4
exchange  {4,100000}           4    400000     132.5   107.1..137.3    0.33     7.9    0.9       0    10295     6508   2.7
exchange  {4,100000}           8    400000      83.7    67.6..141.5    0.21    12.4    0.9       3     8044     8044   4.7
exchange  {4,100000}          16    400000      73.3     65.5..83.0    0.18    18.7    1.2       0     4971     9363   5.8
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
stream    {1000,100,1000}      1    101000     112.3   106.2..117.9    1.11   107.2   13.2       0      725     1088   1.2
stream    {1000,100,1000}      2    102000      75.4     66.5..76.2    0.74    63.5   16.4       0      672     1762   2.4
stream    {1000,100,1000}      4    104000      53.9     46.6..59.8    0.52    43.2   21.6       0      672     1091   3.7
stream    {1000,100,1000}      8    108000      90.1    63.2..102.6    0.83    89.5   29.6       0      277      672   3.6
stream    {1000,100,1000}     16    116000     117.1   109.6..126.7    1.01   111.5   37.6       0      138      672   3.3
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
epochs    {1000,100}           1    101000     112.3   106.5..127.2    1.11    12.5   12.8       0     8993     1760   1.2
epochs    {1000,100}           2    102000      62.5     56.5..68.4    0.61    16.3   16.0       0     4608     1899   2.3
epochs    {1000,100}           4    104000      51.0     41.4..55.5    0.49    36.0   20.7       0     1760     2852   3.7
epochs    {1000,100}           8    108000      72.7     72.4..88.3    0.67    56.6   27.9       0     1088     1770   3.2
epochs    {1000,100}          16    116000     133.5   115.3..171.7    1.15    93.7   36.1       0     1088     2885   3.0
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
loop      {1000,100}           1    100100      82.8     77.7..85.3    0.83     0.2    0.2       0      191       15   1.1
loop      {1000,100}           2    100100      38.7     37.7..39.5    0.39     0.3    0.2       0      105       27   2.1
loop      {1000,100}           4    100100      21.0     20.0..23.2    0.21     0.3    0.2       0       65       52   3.9
loop      {1000,100}           8    100100      22.6     20.2..22.8    0.23     0.8    0.3       0       40       65   5.8
loop      {1000,100}          16    100100      18.9     18.4..24.0    0.19     0.1    0.3       0       40      105   6.6
== push size
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
epochs    {1000,100}           1    101000     106.1   102.7..110.5    1.05    10.3   12.8       0     9345     1173   1.0
epochs    {100,1000}           1    100100      75.9     73.3..83.7    0.76     3.9    4.2       0     9345      362   1.0
epochs    {10,10000}           1    100010      70.7     64.1..77.0    0.71     6.1    3.7       0    17517     1173   0.8
shape     params               W     steps    run ms    min..max ms us/step  fed ms coord% mailbox   wrk KB coord KB  busy
epochs    {1000,100}           8    108000      78.2     65.3..82.9    0.72    55.5   27.9       0      725     2863   3.2
epochs    {100,1000}           8    100800      17.9     16.9..18.7    0.18    10.6    7.8       0     1088      501   5.8
epochs    {10,10000}           8    100080      20.3     17.3..27.1    0.20    17.5    4.3       0     1088     3435   5.1
```

## What it says

Ideal without coordination -- W single runtimes at once, each on a
W-th -- against the concurrent runtime on `pipeline {4,100000}`:

```
W                        1      2      4      8     16
independent singles    244    184     73     41      -   ms
concurrent runtime     281    162     97     71     60   ms
speedup over single    1.0    1.7    2.9    3.9    4.6   (single: 277 ms)
ideal's own speedup    1.0    1.3    3.3    6.0
```

Eight processes that share nothing get 6.0× here against 5.2× on the
laptop; the concurrent runtime gets 3.9× at 8 workers, and 4.6× with
16 workers on the 8 processors, the oversubscription hiding the wait
for the push and the tail. The gap to the ideal at 8 workers is the
same 30 ms as on the laptop: 14 ms of push (`fed ms`), the items sent
one by one to one subscriber, and a few ms of protocol at 0.9 % of
the reductions. The rows of `epochs` and `stream` over the workers and
over the push size repeat the laptop's: a push of 100 items is bound
by the 4W messages it costs, a push of 1000 brings the coordinator to
8 %.

Not answered here: whether the bimodal runs at 16 schedulers are the
laptop's alone. The server has 8 processors, and `+S 16` on it would
be oversubscription, not the same question.

## Correction

The outliers here -- `pipeline` at 8 workers 68.5..274.0 and the like
-- and the question of the 16 schedulers were the bench's consumer
keeping its mailbox on the heap, see the corrections in
`BASELINE.md`; and `exchange` here measured no exchange, for the
reason given there. The rest of the numbers stand.
