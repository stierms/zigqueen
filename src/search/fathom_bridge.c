/* Original ZigQueen ABI glue. Fathom remains the vendored MIT dependency.
 * Only the process-wide Zig service calls these functions. Use public APIs;
 * no search/tool binds private Fathom _impl symbols or its mutable globals. */
#include "tbprobe.h"
bool zq_tb_init(const char *path) { return tb_init(path); }
void zq_tb_free(void) { tb_free(); }
unsigned zq_tb_largest(void) { return TB_LARGEST; }
unsigned zq_tb_wdl(uint64_t white, uint64_t black, uint64_t kings,
    uint64_t queens, uint64_t rooks, uint64_t bishops, uint64_t knights,
    uint64_t pawns, unsigned ep, bool turn) {
    return tb_probe_wdl(white, black, kings, queens, rooks, bishops, knights,
        pawns, 0, 0, ep, turn);
}
unsigned zq_tb_root(uint64_t white, uint64_t black, uint64_t kings,
    uint64_t queens, uint64_t rooks, uint64_t bishops, uint64_t knights,
    uint64_t pawns, unsigned rule50, unsigned ep, bool turn, unsigned *results) {
    return tb_probe_root(white, black, kings, queens, rooks, bishops, knights,
        pawns, rule50, 0, ep, turn, results);
}
