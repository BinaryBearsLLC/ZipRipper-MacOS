#include <metal_stdlib>
using namespace metal;

// WinZip AES uses PBKDF2-HMAC-SHA1, 1000 rounds. Only the derived-key
// block containing the two password-verifier bytes is needed here.
static uint rol(uint x, uint n) { return (x << n) | (x >> (32 - n)); }
static void sha1Initial(thread uint *s) {
    s[0]=0x67452301; s[1]=0xefcdab89; s[2]=0x98badcfe;
    s[3]=0x10325476; s[4]=0xc3d2e1f0;
}
static void sha1Block(thread uint *s, thread const uint *input) {
    uint w[80];
    for (uint i=0; i<16; ++i) w[i]=input[i];
    for (uint i=16; i<80; ++i) w[i]=rol(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);
    uint a=s[0], b=s[1], c=s[2], d=s[3], e=s[4];
    for (uint i=0; i<80; ++i) {
        uint f, k;
        if (i<20) { f=(b&c)|((~b)&d); k=0x5a827999; }
        else if (i<40) { f=b^c^d; k=0x6ed9eba1; }
        else if (i<60) { f=(b&c)|(b&d)|(c&d); k=0x8f1bbcdc; }
        else { f=b^c^d; k=0xca62c1d6; }
        uint t=rol(a,5)+f+e+k+w[i]; e=d; d=c; c=rol(b,30); b=a; a=t;
    }
    s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e;
}
static void hmacShort(thread const uint *inner, thread const uint *outer,
                      thread const uint *messageBlock, thread uint *digest) {
    for (uint i=0; i<5; ++i) digest[i]=inner[i];
    sha1Block(digest,messageBlock);
    uint block[16]={0};
    for (uint i=0; i<5; ++i) block[i]=digest[i];
    block[5]=0x80000000; block[15]=(64+20)*8;
    for (uint i=0; i<5; ++i) digest[i]=outer[i];
    sha1Block(digest,block);
}
kernel void winZipAESVerifier(device const uchar *passwords [[buffer(0)]],
                             device const uint *lengths [[buffer(1)]],
                             device const uchar *salt [[buffer(2)]],
                             constant uint *params [[buffer(3)]],
                             device uint *survivors [[buffer(4)]],
                             uint id [[thread_position_in_grid]]) {
    if (id>=params[0]) return;
    uint length=lengths[id];
    // Defensive preservation: host normally excludes these candidates.
    if (length>64) { survivors[id]=1; return; }
    uint key[16]={0};
    for (uint i=0; i<length; ++i) key[i/4]|=uint(passwords[id*64+i])<<(24-(i%4)*8);
    uint inner[5], outer[5], block[16];
    sha1Initial(inner); sha1Initial(outer);
    for (uint i=0; i<16; ++i) block[i]=key[i]^0x36363636;
    sha1Block(inner,block);
    for (uint i=0; i<16; ++i) block[i]=key[i]^0x5c5c5c5c;
    sha1Block(outer,block);
    for (uint i=0; i<16; ++i) block[i]=0;
    uint saltLength=params[1];
    for (uint i=0; i<saltLength; ++i) block[i/4]|=uint(salt[i])<<(24-(i%4)*8);
    block[saltLength/4]=params[2]; // salt lengths are multiples of four.
    block[(saltLength+4)/4]=0x80000000;
    block[15]=(64+saltLength+4)*8;
    uint u[5], accumulator[5];
    hmacShort(inner,outer,block,u);
    for (uint i=0; i<5; ++i) accumulator[i]=u[i];
    for (uint round=1; round<1000; ++round) {
        for (uint i=0; i<16; ++i) block[i]=0;
        for (uint i=0; i<5; ++i) block[i]=u[i];
        block[5]=0x80000000; block[15]=(64+20)*8;
        hmacShort(inner,outer,block,u);
        for (uint i=0; i<5; ++i) accumulator[i]^=u[i];
    }
    uint offset=params[3];
    uint first=(accumulator[offset/4]>>(24-(offset%4)*8))&255;
    ++offset;
    uint second=(accumulator[offset/4]>>(24-(offset%4)*8))&255;
    survivors[id]=((first<<8)|second)==params[4] ? 1 : 0;
}
