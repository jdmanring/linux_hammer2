#include <stdio.h>
#include <stdint.h>
#include <string.h>
uint32_t iscsi_crc32(const void *buf, size_t size);
int main(void){
    const char *s="123456789";
    uint32_t got=iscsi_crc32(s,9);
    printf("iscsi_crc32(\"123456789\") = %08x\n", got);
    printf("  CRC-32C (Castagnoli) reference = e3069283 %s\n", got==0xe3069283u?"MATCH":"");
    printf("  CRC-32  (IEEE/zlib)  reference = cbf43926 %s\n", got==0xcbf43926u?"MATCH":"");
    return !(got==0xe3069283u || got==0xcbf43926u);
}
