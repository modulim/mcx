/////////////////////////////////////////////////////////////////////
//
//  MC Extreme  - GPU accelerated Monte-Carlo Simulation
//  
//  Author: Qianqian Fang <fangq at nmr.mgh.harvard.edu>
//  History: 
//    2009/02/14 initial version written in BrookGPU
//    2009/02/15 translated to CUDA
//    2009/02/20 translated to Brook+
//    2009/02/21 added MT random number generator initial version
//    2009/02/24 MT rand now working fine
//
// License: unpublished version, use by author's permission only
//
/////////////////////////////////////////////////////////////////////

#include <stdio.h>
#include "br2cu.h"
#include "mt_rand_s.cu"
#include "tictoc.h"

// dimension of the target domain

#define DIMX 128
#define DIMY 128
#define DIMZ 128

#define DIMYZ (DIMY*DIMZ)
#define DIMXYZ (DIMX*DIMY*DIMZ)
#define INDXYZ(ii,jj,kk)  ((ii)*DIMYZ+(jj)*DIMZ+(kk))
#define MAX_MT_RAND 4294967296
#define TWO_PI 6.28318530717959f


// #define FAST_MATH   /*define this to use the __sincos versions*/


#define MAX_N      1024
#define MAX_THREAD 128
#define MAX_EVENT  1
#define MAX_PROP   256
#define MAX_MEDIA_CACHE   53248  /*52k for local media read*/


#define MEDIA_BITS  2            /*2^2=4 media types*/
#define MEDIA_PACK  ((8/MEDIA_BITS)>>1)            /*one byte packs 2^MEDIA_PACK voxel*/
#define MEDIA_MOD   ((1<<MEDIA_PACK)-1)    /*one byte packs 2^MEDIA_PACK voxel*/
#define MEDIA_MASK  ((1<<(MEDIA_BITS))-1)

#define MINUS_SAME_VOXEL -9999.f

#define GPUDIV(a,b)  __fdividef((a),(b))


typedef unsigned char uchar;

/******************************
typedef struct PhotonData {
  float4 pos;  // x,y,z,weight
  float4 dir;  // ix,iy,iz,dummy
  float3 len; // resid,tot,count
  uint   seed; // random seed
} Photon;
******************************/

__constant__ float2 gproperty[MAX_PROP];
__constant__ uint   gmediacache[MAX_MEDIA_CACHE>>2];


kernel void mcx_main_loop(int totalmove,uchar media[],float field[],float3 vsize,float minstep, 
     float lmax, float gg, float gg2,float ggx2, float4 p0,float4 c0,float3 maxidx,
     uint n_seed[],float4 n_pos[],float4 n_dir[],float3 n_len[]){

     int idx= blockDim.x * blockIdx.x + threadIdx.x;

     float4 npos=n_pos[idx];
     float4 ndir=n_dir[idx];
     float3 nlen=n_len[idx];
     float4 ndir0;

     int    i, idx1d, idxorig, mediaid;
     uint   ran;
     float2 prop;

     float step,len,phi,cphi,sphi,foo,theta,stheta,ctheta,tmp0,tmp1,tmp2;

     mt19937si(n_seed[idx]);
     __syncthreads();

     idx1d=int(floorf(npos.x)*DIMYZ+floorf(npos.y)*DIMZ+floorf(npos.z));
     idxorig=idx1d;

     for(i=0;i<totalmove;i++){
	  if(nlen.x<=0.f) {  /* if this photon finished the current jump */

	       ndir0=ndir;
	       ran=mt19937s(); /*random number [0,MAX_MT_RAND)*/

#ifndef FAST_MATH
   	       nlen.x=-logf(GPUDIV((float)ran,MAX_MT_RAND)); /*probability of the next jump*/
#else
               nlen.x=-__logf(GPUDIV((float)ran,MAX_MT_RAND)); /*probability of the next jump*/
#endif

	       if(npos.w<1.f){ /*weight*/
                       ran=mt19937s();
		       phi=GPUDIV(TWO_PI*ran,MAX_MT_RAND);
#ifndef FAST_MATH
                       sincosf(phi,&sphi,&cphi);
#else
                       __sincosf(phi,&sphi,&cphi);
#endif
		       ran=mt19937s();
		       foo = (1.f - gg2)/(1.f - gg + GPUDIV(ggx2*ran,MAX_MT_RAND));
		       foo = foo * foo;
		       foo = GPUDIV((1.f + gg2 - foo),ggx2);
		       theta=acosf(foo);
#ifndef FAST_MATH
		       stheta=sinf(theta);
#else
                       stheta=__sinf(theta);
#endif
		       ctheta=foo;
		       if( ndir.z>-1.f && ndir.z<1.f ) {
		           tmp0=1.f-ndir.z*ndir.z;
		           tmp1=rsqrtf(tmp0);
		           tmp2=stheta*tmp1;
			   if(stheta>1e-20) {  /*strang: if stheta=0, I will get nan :(  FQ */
			     ndir=float4(
				tmp2*(ndir0.x*ndir0.z*cphi - ndir0.y*sphi) + ndir0.x*ctheta,
				tmp2*(ndir0.y*ndir0.z*cphi + ndir0.x*sphi) + ndir0.y*ctheta,
				-tmp2*tmp0*cphi                            + ndir0.z*ctheta,
				ndir0.w
				);
                             }
		       }else{
			   ndir=float4(stheta*cphi,stheta*sphi,ctheta,ndir0.w);
 		       }
                       ndir.w++;
	       }
	  }
          mediaid=media[idx1d];
	  prop=gproperty[mediaid];
	  len=minstep*prop.y;

	  if(len>nlen.x){  /*scattering ends in this voxel*/
               step=GPUDIV(nlen.x,prop.y);
   	       npos=float4(npos.x+ndir.x*step,npos.y+ndir.y*step,npos.z+ndir.z*step,npos.w*expf(-prop.x * step ));
	       nlen.x=MINUS_SAME_VOXEL;
	       nlen.y+=step;
	  }else{                      /*otherwise, move minstep*/
   	       npos=float4(npos.x+ndir.x,npos.y+ndir.y,npos.z+ndir.z,npos.w*expf(-prop.x * minstep ));
	       nlen.x-=len;     /*remaining probability*/
	       nlen.y+=minstep; /*total moved length along the current jump*/
               idx1d=int(floorf(npos.x)*DIMYZ+floorf(npos.y)*DIMZ+floorf(npos.z));
	  }
	  if(nlen.x>lmax||npos.x<0||npos.y<0||npos.z<0||npos.x>maxidx.x||npos.y>maxidx.y||npos.z>maxidx.z){
	      /*if hit the boundary or exit the domain, launch a new one*/
	      npos=p0;
	      ndir=c0;
	      nlen=float3(0.f,0.f,nlen.z+1);
              idx1d=idxorig;
	  }else{
	      field[idx1d]+=(nlen.x>0)?npos.w:0.f;
	  }
     }
     n_seed[idx]=(ran&0xffffffffu);
     n_pos[idx]=npos;
     n_dir[idx]=ndir;
     n_len[idx]=nlen;
}

void savedata(float *dat,int len,char *name){
     FILE *fp;
     fp=fopen(name,"wb");
     fwrite(dat,sizeof(float),len,fp);
     fclose(fp);
}

int main (int argc, char *argv[]) {

     float3 vsize=float3(1.f,1.f,1.f);
     float  minstep=1.f;
     float  lmax=100.f;
     float  gg=0.98f;
     float4 p0=float4(10,10,0,1.f);
     float4 c0=float4(0.f,0.f,1.f,0.f);
     float3 maxidx=float3(DIMX-1,DIMY-1,DIMZ-1);
     float2 property[MAX_PROP]={float2(0.f,0.f),float2(0.009f,0.75f),  // 1st is air
                                float2(0.006f,0.75f),float2(0.009f,0.95f)};

     int i,j,k;
     int total=MAX_EVENT;
     int photoncount=0, count;
     int tic;
     int3 cp0=int3(0,0,0),cp1=int3(20,20,40);

     dim3 ThreadDim(1);
     dim3 GridDim(MAX_N/MAX_THREAD);
     dim3 BlockDim(MAX_THREAD);

     uchar  media[DIMXYZ];
     float  field[DIMXYZ];
     uint   mediacache[MAX_MEDIA_CACHE>>2];

     float4 Ppos[MAX_N];
     float4 Pdir[MAX_N];
     float3 Plen[MAX_N];
     uint   Pseed[MAX_N];

     if(argc>1){
	   total=atoi(argv[1]);
     }

     uchar *gmedia;
     cudaMalloc((void **) &gmedia, sizeof(uchar)*(DIMXYZ));
     float *gfield;
     cudaMalloc((void **) &gfield, sizeof(float)*(DIMXYZ));

     float4 *gPpos;
     cudaMalloc((void **) &gPpos, sizeof(float4)*(MAX_N));
     float4 *gPdir;
     cudaMalloc((void **) &gPdir, sizeof(float4)*(MAX_N));
     float3 *gPlen;
     cudaMalloc((void **) &gPlen, sizeof(float3)*(MAX_N));
     uint   *gPseed;
     cudaMalloc((void **) &gPseed, sizeof(uint)*(MAX_N));

     for (i=0; i<DIMX; i++)
      for (j=0; j<DIMY; j++)
       for (k=0; k<DIMZ; k++) {
           media[INDXYZ(i,j,k)]=1; 
	   field[INDXYZ(i,j,k)]=0.f;
       }

     count=0;
     memset(mediacache,0,MAX_MEDIA_CACHE);
     for (i=cp0.x; i<cp1.x; i++)
      for (j=cp0.y; j<cp1.y; j++)
       for (k=cp0.z; k<cp1.z; k++) {
//         printf("[%d %d %d]: %d %d %d %d (%d)\n",i,j,k,count,MEDIA_MASK,count>>MEDIA_PACK,(count & MEDIA_MOD)*MEDIA_BITS,
//                (media[INDXYZ(i,j,k)] & MEDIA_MASK )<<((count & MEDIA_MOD)*MEDIA_BITS) );
           mediacache[count>>MEDIA_PACK] |=  (media[INDXYZ(i,j,k)] & MEDIA_MASK )<<((count & MEDIA_MOD)*MEDIA_BITS );
           count++;
       }
     for (i=0; i<5; i++) {
	printf("XX %d\n",mediacache[i]);
     }
     srand(time(0));
     for (i=0; i<MAX_N; i++) {
	   Ppos[i]=p0;  /* initial position */
           Pdir[i]=c0;
           Plen[i]=float3(0.f,0.f,0.f);
	   Pseed[i]=rand();
     }

     tic=GetTimeMillis();

     cudaMemcpy(gPpos,  Ppos,  sizeof(float4)*MAX_N,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPdir,  Pdir,  sizeof(float4)*MAX_N,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPlen,  Plen,  sizeof(float3)*MAX_N,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPseed, Pseed, sizeof(uint)*MAX_N,     cudaMemcpyHostToDevice);
     cudaMemcpy(gfield, field, sizeof(float)*DIMXYZ, cudaMemcpyHostToDevice);
     cudaMemcpy(gmedia, media, sizeof(uchar)*DIMXYZ,cudaMemcpyHostToDevice);
     cudaMemcpyToSymbol(gproperty, property, MAX_PROP*sizeof(float2), 0, cudaMemcpyHostToDevice);
     cudaMemcpyToSymbol(gmediacache, mediacache, MAX_MEDIA_CACHE, 0, cudaMemcpyHostToDevice);

     printf("complete cudaMemcpy : %d ms\n",GetTimeMillis()-tic);

     mcx_main_loop<<<GridDim,BlockDim>>>(total,gmedia,gfield,vsize,minstep,lmax,gg,gg*gg,2.f*gg,\
        	 p0,c0,maxidx,gPseed,gPpos,gPdir,gPlen);

     printf("complete launching kernels : %d ms\n",GetTimeMillis()-tic);

     cudaMemcpy(Ppos,  gPpos, sizeof(float4)*MAX_N, cudaMemcpyDeviceToHost);

     printf("complete retrieving pos : %d ms\n",GetTimeMillis()-tic);

     cudaMemcpy(Pdir,  gPdir, sizeof(float4)*MAX_N, cudaMemcpyDeviceToHost);
     cudaMemcpy(Plen,  gPlen, sizeof(float3)*MAX_N, cudaMemcpyDeviceToHost);
     cudaMemcpy(Pseed, gPseed,sizeof(uint)*MAX_N,   cudaMemcpyDeviceToHost);
     cudaMemcpy(field, gfield,sizeof(float)*DIMXYZ,cudaMemcpyDeviceToHost);

     printf("complete retrieving all : %d ms\n",GetTimeMillis()-tic);

     for (i=0; i<MAX_N; i++) {
	  photoncount+=(int)Plen[i].z;
     }
     for (i=0; i<16; i++) {
           printf("% 4d[A% f % f % f]C%3d J%3d% 8f(P% 6.3f % 6.3f % 6.3f)T% 5.3f L% 5.3f %f %f\n", i,
            Pdir[i].x,Pdir[i].y,Pdir[i].z,(int)Plen[i].z,(int)Pdir[i].w,Ppos[i].w, 
            Ppos[i].x,Ppos[i].y,Ppos[i].z,Plen[i].y,Plen[i].x,(float)Pseed[i], Pdir[i].x*Pdir[i].x+Pdir[i].y*Pdir[i].y+Pdir[i].z*Pdir[i].z);
     }
     printf("simulating total photon %d\n",photoncount);
     savedata(field,DIMX*DIMY*DIMZ,"field.dat");

     cudaFree(gmedia);
     cudaFree(gmediacache);
     cudaFree(gfield);
     cudaFree(gPpos);
     cudaFree(gPdir);
     cudaFree(gPlen);
     cudaFree(gPseed);

     return 0;

}
