# all on DRAM
./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 0 -N 0 -S 46
# pchase on Optane, seq on DRAM
./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 2 -N 0 -S 46
# inverse
./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 0 -N 2 -S 46
# all on Optane
./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 2 -N 2 -S 46
