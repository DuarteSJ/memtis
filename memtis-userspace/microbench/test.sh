# all on DRAM
echo -e "\n===All on DRAM===\n"
time ./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 0 -N 0 -S 46
# pchase on Optane, seq on DRAM
echo -e "\n===pchase on Optane, seq on DRAM===\n"
time ./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 2 -N 0 -S 46
# inverse
echo -e "\n===pchase on DRAM, seq on Optane===\n"
time ./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 0 -N 2 -S 46
# all on Optane
echo -e "\n===All on Optane===\n"
time ./bench -R 0.5 -i 2 -A 2048 -B 2048 -r 2 -N 2 -S 46
