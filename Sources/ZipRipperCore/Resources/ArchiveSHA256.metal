#include <metal_stdlib>
using namespace metal;
constant uint sk[64]={
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
static uint rr(uint a,uint n){return (a>>n)|(a<<(32-n));}
static void initial(thread uint*s){s[0]=0x6a09e667;s[1]=0xbb67ae85;s[2]=0x3c6ef372;s[3]=0xa54ff53a;s[4]=0x510e527f;s[5]=0x9b05688c;s[6]=0x1f83d9ab;s[7]=0x5be0cd19;}
static void block256(thread uint*s,thread const uint*input){
 uint w[64];for(uint i=0;i<16;i++)w[i]=input[i];
 for(uint i=16;i<64;i++){uint a=w[i-15],b=w[i-2];w[i]=w[i-16]+(rr(a,7)^rr(a,18)^(a>>3))+w[i-7]+(rr(b,17)^rr(b,19)^(b>>10));}
 uint a=s[0],b=s[1],c=s[2],d=s[3],e=s[4],f=s[5],g=s[6],h=s[7];
 for(uint i=0;i<64;i++){uint t=h+(rr(e,6)^rr(e,11)^rr(e,25))+((e&f)^((~e)&g))+sk[i]+w[i];uint u=(rr(a,2)^rr(a,13)^rr(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+t;d=c;c=b;b=a;a=t+u;}
 s[0]+=a;s[1]+=b;s[2]+=c;s[3]+=d;s[4]+=e;s[5]+=f;s[6]+=g;s[7]+=h;
}
static void addByte(thread uint*s,thread uint*b,thread uint&n,uchar value){b[n/4]|=uint(value)<<(24-(n%4)*8);if(++n==64){block256(s,b);for(uint i=0;i<16;i++)b[i]=0;n=0;}}
static void finish256(thread uint*s,thread uint*b,thread uint&n,ulong length){addByte(s,b,n,0x80);while(n!=56)addByte(s,b,n,0);for(int i=7;i>=0;i--)addByte(s,b,n,uchar((length*8)>>(i*8)));}
// Each launch processes <=4096 KDF rounds and persists all state, permitting
// cancellation between commands without waiting for the entire KDF.
// params: count, saltLength, roundStart, roundEnd, totalRounds.
kernel void sevenZIPKey(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint s[8],b[16]={0},n=0;device uint*saved=state+id*40;
 if(p[2]==0)initial(s);else{for(uint i=0;i<8;i++)s[i]=saved[i];for(uint i=0;i<16;i++)b[i]=saved[8+i];n=saved[24];}
 for(uint r=p[2];r<p[3];r++){for(uint i=0;i<p[1];i++)addByte(s,b,n,salt[i]);for(uint i=0;i<len[id];i++)addByte(s,b,n,pw[id*256+i]);for(uint i=0;i<8;i++)addByte(s,b,n,uchar(ulong(r)>>(i*8)));}
 if(p[3]==p[4])finish256(s,b,n,ulong(p[4])*(p[1]+len[id]+8));
 for(uint i=0;i<8;i++)saved[i]=s[i];for(uint i=0;i<16;i++)saved[8+i]=b[i];saved[24]=n;
}
static void hmac256(thread const uint*inner,thread const uint*outer,thread const uint*b,thread uint*out){
 for(uint i=0;i<8;i++)out[i]=inner[i];block256(out,b);uint tmp[16]={0};for(uint i=0;i<8;i++)tmp[i]=out[i];tmp[8]=0x80000000;tmp[15]=768;for(uint i=0;i<8;i++)out[i]=outer[i];block256(out,tmp);
}
kernel void rar5Key(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint inner[8],outer[8],u[8],acc[8],b[16]={0};device uint*saved=state+id*40;
 if(p[2]==0){uint key[16]={0};for(uint i=0;i<len[id];i++)key[i/4]|=uint(pw[id*256+i])<<(24-(i%4)*8);initial(inner);initial(outer);for(uint i=0;i<16;i++)b[i]=key[i]^0x36363636;block256(inner,b);for(uint i=0;i<16;i++)b[i]=key[i]^0x5c5c5c5c;block256(outer,b);for(uint i=0;i<16;i++)b[i]=0;for(uint i=0;i<16;i++)b[i/4]|=uint(salt[i])<<(24-(i%4)*8);b[4]=1;b[5]=0x80000000;b[15]=672;hmac256(inner,outer,b,u);for(uint i=0;i<8;i++)acc[i]=u[i];}
 else{for(uint i=0;i<8;i++){inner[i]=saved[8+i];outer[i]=saved[16+i];u[i]=saved[24+i];acc[i]=saved[i];}}
 for(uint r=max(p[2],1u);r<p[3];r++){for(uint i=0;i<16;i++)b[i]=0;for(uint i=0;i<8;i++)b[i]=u[i];b[8]=0x80000000;b[15]=768;hmac256(inner,outer,b,u);for(uint i=0;i<8;i++)acc[i]^=u[i];}
 for(uint i=0;i<8;i++){saved[i]=acc[i];saved[8+i]=inner[i];saved[16+i]=outer[i];saved[24+i]=u[i];}
}
kernel void pdfR5Key(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint s[8],b[16]={0},n=0;initial(s);for(uint i=0;i<len[id];i++)addByte(s,b,n,pw[id*256+i]);for(uint i=0;i<8;i++)addByte(s,b,n,salt[i]);finish256(s,b,n,len[id]+8);for(uint i=0;i<8;i++)state[id*40+i]=s[i];
}
// Traditional ZIP's 12-byte encryption-header check. A match is only a
// probabilistic survivor and always receives John's complete ZIP validation.
static uint zipCRC(uint c,uchar b){c^=uint(b);for(uint i=0;i<8;i++)c=(c>>1)^((c&1)?0xedb88320u:0u);return c;}
static void zipUpdate(thread uint&a,thread uint&b,thread uint&c,uchar value){a=zipCRC(a,value);b=(b+(a&255))*134775813u+1;c=zipCRC(c,uchar(b>>24));}
kernel void zipCryptoHeader(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint a=0x12345678,b=0x23456789,c=0x34567890;
 for(uint i=0;i<len[id];i++)zipUpdate(a,b,c,pw[id*256+i]);uchar plain[12];
 for(uint i=0;i<12;i++){uint t=(c&65535)|2;plain[i]=salt[i]^uchar((t*(t^1))>>8);zipUpdate(a,b,c,plain[i]);}
 bool last=plain[11]==salt[12]||plain[11]==salt[14];bool previous=salt[16]!=2||plain[10]==salt[13]||plain[10]==salt[15];
 for(uint i=0;i<8;i++)state[id*40+i]=0;state[id*40]=last&&previous?1:0;
}

constant uchar pdfPad[32]={0x28,0xbf,0x4e,0x5e,0x4e,0x75,0x8a,0x41,0x64,0x00,0x4e,0x56,0xff,0xfa,0x01,0x08,0x2e,0x2e,0x00,0xb6,0xd0,0x68,0x3e,0x80,0x2f,0x0c,0xa9,0xfe,0x64,0x53,0x69,0x7a};
constant uint mdK[64]={0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391};
constant uint mdShift[16]={7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21};
static void md5(thread const uchar*input,uint length,thread uchar*out){
 uint s[4]={0x67452301,0xefcdab89,0x98badcfe,0x10325476};uint blocks=(length+9+63)/64;
 for(uint part=0;part<blocks;part++){uint w[16]={0};for(uint j=0;j<64;j++){uint pos=part*64+j;uchar v=pos<length?input[pos]:(pos==length?0x80:0);if(pos>=blocks*64-8)v=uchar(ulong(length*8)>>((pos-(blocks*64-8))*8));w[j/4]|=uint(v)<<((j%4)*8);}
 uint a=s[0],b=s[1],c=s[2],d=s[3];for(uint j=0;j<64;j++){uint f,g;if(j<16){f=(b&c)|((~b)&d);g=j;}else if(j<32){f=(d&b)|((~d)&c);g=(5*j+1)%16;}else if(j<48){f=b^c^d;g=(3*j+5)%16;}else{f=c^(b|(~d));g=(7*j)%16;}uint x=a+f+mdK[j]+w[g],n=mdShift[(j/16)*4+j%4];a=d;d=c;c=b;b+=(x<<n)|(x>>(32-n));}s[0]+=a;s[1]+=b;s[2]+=c;s[3]+=d;
 }for(uint i=0;i<16;i++)out[i]=uchar(s[i/4]>>((i%4)*8));
}
static void rc4(thread const uchar*key,uint keyLength,thread uchar*data,uint length){uchar box[256];for(uint i=0;i<256;i++)box[i]=uchar(i);uint j=0;for(uint i=0;i<256;i++){j=(j+box[i]+key[i%keyLength])&255;uchar t=box[i];box[i]=box[j];box[j]=t;}uint i=0;j=0;for(uint n=0;n<length;n++){i=(i+1)&255;j=(j+box[i])&255;uchar t=box[i];box[i]=box[j];box[j]=t;data[n]^=box[(uint(box[i])+box[j])&255];}}
kernel void pdfLegacyKey(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint revision=salt[0],keyLength=salt[1],idLength=salt[3];uchar input[200],digest[32]={0},key[16];uint pwLength=min(len[id],32u);
 for(uint i=0;i<32;i++)input[i]=i<pwLength?pw[id*256+i]:pdfPad[i-pwLength];for(uint i=0;i<32;i++)input[32+i]=salt[8+i];for(uint i=0;i<4;i++)input[64+i]=salt[4+i];for(uint i=0;i<idLength;i++)input[68+i]=salt[40+i];uint size=68+idLength;
 if(revision>=4&&salt[2]==0){for(uint i=0;i<4;i++)input[size++]=255;}
 md5(input,size,digest);if(revision>=3){for(uint r=0;r<50;r++){for(uint i=0;i<keyLength;i++)input[i]=digest[i];md5(input,keyLength,digest);}}
 for(uint i=0;i<keyLength;i++)key[i]=digest[i];for(uint i=0;i<32;i++)digest[i]=pdfPad[i];uint outLength=32;
 if(revision>=3){for(uint i=0;i<32;i++)input[i]=pdfPad[i];for(uint i=0;i<idLength;i++)input[32+i]=salt[40+i];md5(input,32+idLength,digest);outLength=16;}
 rc4(key,keyLength,digest,outLength);if(revision>=3){uchar roundKey[16];for(uint r=1;r<20;r++){for(uint i=0;i<keyLength;i++)roundKey[i]=key[i]^uchar(r);rc4(roundKey,keyLength,digest,outLength);}}
 for(uint i=0;i<8;i++)state[id*40+i]=0;for(uint i=0;i<outLength;i++)state[id*40+i/4]|=uint(digest[i])<<(24-(i%4)*8);
}

static void addSHA1(thread uint*s,thread uint*b,thread uint&n,uchar value){b[n/4]|=uint(value)<<(24-(n%4)*8);if(++n==64){sha1Block(s,b);for(uint i=0;i<16;i++)b[i]=0;n=0;}}
static void finishSHA1(thread uint*s,thread uint*b,thread uint&n,ulong length){addSHA1(s,b,n,0x80);while(n!=56)addSHA1(s,b,n,0);for(int i=7;i>=0;i--)addSHA1(s,b,n,uchar((length*8)>>(i*8)));}
kernel void rar3Key(device const uchar*pw[[buffer(0)]],device const uint*len[[buffer(1)]],device const uchar*salt[[buffer(2)]],constant uint*p[[buffer(3)]],device uint*state[[buffer(4)]],uint id[[thread_position_in_grid]]){
 if(id>=p[0])return;uint s[5],b[16]={0},n=0,iv[4]={0};device uint*saved=state+id*40;
 if(p[2]==0)sha1Initial(s);else{for(uint i=0;i<5;i++)s[i]=saved[i];for(uint i=0;i<16;i++)b[i]=saved[8+i];n=saved[28];for(uint i=0;i<4;i++)iv[i]=saved[24+i];}
 for(uint r=p[2];r<p[3];r++){for(uint i=0;i<len[id];i++)addSHA1(s,b,n,pw[id*256+i]);for(uint i=0;i<8;i++)addSHA1(s,b,n,salt[i]);for(uint i=0;i<3;i++)addSHA1(s,b,n,uchar(r>>(i*8)));
 if(r%16384==0){uint tmp[5],buf[16],count=n;for(uint i=0;i<5;i++)tmp[i]=s[i];for(uint i=0;i<16;i++)buf[i]=b[i];finishSHA1(tmp,buf,count,ulong(r+1)*(len[id]+11));uint index=r/16384;iv[index/4]|=(tmp[4]&255)<<(24-(index%4)*8);}}
 for(uint i=0;i<16;i++)saved[8+i]=b[i];saved[28]=n;for(uint i=0;i<4;i++)saved[24+i]=iv[i];
 if(p[3]==p[4]){finishSHA1(s,b,n,ulong(p[4])*(len[id]+11));for(uint i=0;i<4;i++){uint v=s[i];saved[i]=(v>>24)|((v>>8)&0xff00)|((v<<8)&0xff0000)|(v<<24);saved[4+i]=iv[i];}}
 else for(uint i=0;i<5;i++)saved[i]=s[i];
}
