#include "fingering.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Positions are measured in piano keys, not semitones: white keys are one step apart and a black key sits halfway
   between its neighbours, so a scale step is about one finger wherever it lands (C=0, C♯=0.5, D=1 … B=6, octave=7). */
static double keypos(int midi) {
    static const double place[12]={0,.5,1,1.5,2,3,3.5,4,4.5,5,5.5,6};
    int octave=midi>=0?midi/12:(midi-11)/12; return octave*7+place[midi-octave*12];
}
/* Notes that start together in one hand, sorted by x (x = key position for the right hand, its negative for the left,
   so that "up" always means away from the thumb). At most five are fingered. */
typedef struct {
    int k;                       /* fingered notes */
    double x[5]; int midi[5];
    double end[5];               /* when each note is released, in beats */
    double onset;
    size_t index[5];             /* event index of each fingered note (offline) */
    double xmin,xmax; unsigned hand;   /* the hand's whole range in this passage, for its outermost notes */
    bool isolated;                     /* no other note of the hand within .6 beats: a bass note, a pedal tone */
} Group;
typedef struct { unsigned char f[5]; double pos, cost; } Candidate;

/* Where each finger rests relative to the thumb on a relaxed hand: one key apart. */
static const double OFF[6]={0,0,1,2,3,4};
/* Comfortable span between two fingers of one hand (a < b), in keys (an octave is 7). */
static const double MAXS[6][6]={
    {0},{0,0,4,5,6,8},{0,0,0,3,4,5},{0,0,0,0,3,4},{0,0,0,0,0,3},{0}
};
static bool black(int midi) { int pc=((midi%12)+12)%12; return pc==1 || pc==3 || pc==6 || pc==8 || pc==10; }

static double static_cost(const Group *g, const unsigned char *f, double *pos) {
    double cost=0,sum=0;
    for(int i=0;i<g->k;i++) {
        sum+=g->x[i]-OFF[f[i]];
        if(f[i]==1 && black(g->midi[i])) cost+=g->k==1?3:1.0;
        if(f[i]==5 && black(g->midi[i])) cost+=g->k==1?.1:.4;
        if(g->k==1 && f[i]==4) cost+=.5;
        if(i+1<g->k) {
            int a=f[i],b=f[i+1]; double d=g->x[i+1]-g->x[i],natural=OFF[b]-OFF[a],widest=MAXS[a][b],narrowest=(b-a)*.5;
            cost+=3*fmax(0,d-widest)+2*fmax(0,narrowest-d)+.5*fabs(d-natural);
        }
    }
    if(g->k>=3 && f[g->k-1]!=5) cost+=.2; /* chords: little finger on the outer note */
    /* A lone note at the hand's outer edge is the little finger's (a bass note, a top pedal tone), at the inner edge the
       thumb's; a hand that plays one pitch only rests on 5 (left) or 1 (right). */
    if(g->k==1 && g->isolated) {
        if(g->xmax-g->xmin<1) { if(f[0]!=(g->hand?1:5)) cost+=.25; }
        else { if(g->x[0]>=g->xmax-1+1e-9 && f[0]!=5) cost+=.25; if(g->x[0]<=g->xmin+1-1e-9 && f[0]!=1) cost+=.25; }
    }
    *pos=g->k?sum/g->k:0; return cost;
}
/* A key counts as held when it overlaps the new onset by more than a legato articulation (ringing tails are pedal). */
static const double KvHold=.15;
static double held_conflict(const Group *p, const unsigned char *fp, const Group *g, const unsigned char *fc) {
    double cost=0;
    for(int i=0;i<p->k;i++) if(p->end[i]>g->onset+KvHold) for(int j=0;j<g->k;j++) if(fp[i] && fc[j]==fp[i] && g->midi[j]!=p->midi[i]) cost+=10;
    return cost;
}
/* Is the step from one single note to the next a crossing (thumb under going up, a finger over the thumb going down)? */
static bool crossing(const Group *p, const unsigned char *fp, const Group *g, const unsigned char *fc) {
    if(p->k!=1 || g->k!=1 || p->midi[0]==g->midi[0]) return false;
    return (g->x[0]>p->x[0] && fc[0]<fp[0]) || (g->x[0]<p->x[0] && fc[0]>fp[0]);
}
/* Moving from the previous group's fingering to the current one. `rest` means the hand was free in between. */
static double transition(const Group *p, const unsigned char *fp, double posp, const Group *g, const unsigned char *fc, double posc, bool rest) {
    double cost=0,free=rest?.35:1;
    if(p->k==1 && g->k==1) {
        double d=g->x[0]-p->x[0],span=fabs(d); int a=fp[0],b=fc[0];
        if(p->midi[0]==g->midi[0]) cost+=a!=b?.3:0;
        else if(a==b) cost+=rest?.5:8;                                     /* same finger on another key */
        else if(!crossing(p,fp,g,fc)) {
            /* The hand reaches without moving while the step fits the span of the two fingers; beyond it, it stretches. */
            int lo=a<b?a:b,hi=a<b?b:a;
            cost+=free*(3*fmax(0,span-MAXS[lo][hi])+2*fmax(0,(hi-lo)*.5-span)+.3*fabs(span-(OFF[hi]-OFF[lo]))+.2*fabs(posc-posp));
        } else {
            /* Thumb under after 2–4 going up, or 2–4 over the thumb going down; anything else is awkward. */
            bool up=d>0; int other=up?a:b,thumb=up?b:a;
            bool proper=thumb==1 && other>=2 && other<=4;
            cost+=proper?(other==3?1.2:other==4?1.5:3):8;
            cost+=3*fmax(0,span-(proper?other:1));                           /* how far the crossing finger can reach */
        }
    } else {
        cost+=free*fabs(posc-posp);
        for(int i=0;i<p->k;i++) for(int j=0;j<g->k;j++) if(fp[i]==fc[j] && p->midi[i]!=g->midi[j]) cost+=rest?.2:1;
    }
    /* A finger that still holds its key cannot play another one. */
    return cost+held_conflict(p,fp,g,fc);
}
/* All increasing finger choices for k notes (fingers rise with x). */
static int candidates(const Group *g, Candidate *out) {
    int n=0,k=g->k; if(k<1) return 0;
    for(int mask=1;mask<32;mask++) {
        int bits=0; for(int b=0;b<5;b++) if(mask&(1<<b)) bits++;
        if(bits!=k) continue;
        Candidate c={{0},0,0}; int at=0; for(int b=0;b<5;b++) if(mask&(1<<b)) c.f[at++]=(unsigned char)(b+1);
        c.cost=static_cost(g,c.f,&c.pos); out[n++]=c;
    }
    return n;
}
static int compare_x(const void *a, const void *b) { const int *x=a,*y=b; return (x[0]>y[0])-(x[0]<y[0]); }

void kv_finger_events(const KvPianoEvent *events, size_t count, unsigned hand, unsigned char *fingers) {
    if(!events || !fingers || !count) return;
    size_t *order=malloc(count*sizeof(size_t)); Group *groups=malloc(count*sizeof(Group));
    if(!order || !groups) { free(order); free(groups); return; }
    size_t n=0; for(size_t i=0;i<count;i++) if(events[i].hand==hand) { order[n++]=i; fingers[i]=0; }
    /* Stable sort by onset (insertion: performances are nearly sorted already). */
    for(size_t i=1;i<n;i++) for(size_t j=i;j>0 && events[order[j]].beat<events[order[j-1]].beat-1e-9;j--) { size_t t=order[j]; order[j]=order[j-1]; order[j-1]=t; }
    size_t groupCount=0;
    for(size_t i=0;i<n;) {
        size_t j=i; while(j<n && events[order[j]].beat-events[order[i]].beat<.03) j++;
        /* Sort the chord by x, merge equal pitches, keep at most five notes spread over its range. */
        int tmp[64][2]; int m=0;
        for(size_t q=i;q<j && m<64;q++) { int midi=events[order[q]].midi; tmp[m][0]=hand?midi:-midi; tmp[m][1]=(int)q; m++; }
        qsort(tmp,(size_t)m,sizeof(tmp[0]),compare_x);
        int unique[64],u=0; for(int q=0;q<m;q++) if(!u || tmp[q][0]!=tmp[unique[u-1]][0]) unique[u++]=q;
        Group *g=&groups[groupCount++]; memset(g,0,sizeof(*g)); g->onset=events[order[i]].beat;
        int k=u<5?u:5;
        for(int s=0;s<k;s++) {
            int q=unique[k==u?s:(int)lround((double)s*(u-1)/4)];
            const KvPianoEvent *e=&events[order[tmp[q][1]]];
            g->x[s]=hand?keypos(e->midi):-keypos(e->midi); g->midi[s]=e->midi; g->end[s]=e->beat+e->duration; g->index[s]=order[tmp[q][1]];
        }
        g->k=k; i=j;
    }
    { double lo=INFINITY,hi=-INFINITY; for(size_t g=0;g<groupCount;g++) for(int s=0;s<groups[g].k;s++) { lo=fmin(lo,groups[g].x[s]); hi=fmax(hi,groups[g].x[s]); }
      for(size_t g=0;g<groupCount;g++) { groups[g].xmin=lo; groups[g].xmax=hi; groups[g].hand=hand;
          groups[g].isolated=(g==0 || groups[g].onset-groups[g-1].onset>.6) && (g+1==groupCount || groups[g+1].onset-groups[g].onset>.6); } }
    /* Viterbi over the groups. */
    Candidate (*cand)[10]=malloc(groupCount*sizeof(*cand)); int *candCount=malloc(groupCount*sizeof(int));
    double (*best)[10]=malloc(groupCount*sizeof(*best)); int (*from)[10]=malloc(groupCount*sizeof(*from));
    if(cand && candCount && best && from && groupCount) {
        for(size_t g=0;g<groupCount;g++) {
            candCount[g]=candidates(&groups[g],cand[g]);
            for(int c=0;c<candCount[g];c++) {
                best[g][c]=cand[g][c].cost; from[g][c]=-1;
                if(g==0) continue;
                const Group *p=&groups[g-1]; double prevEnd=-INFINITY; for(int s=0;s<p->k;s++) prevEnd=fmax(prevEnd,p->end[s]);
                bool rest=prevEnd<groups[g].onset-.02; double low=INFINITY;
                for(int b=0;b<candCount[g-1];b++) {
                    double v=best[g-1][b]+transition(p,cand[g-1][b].f,cand[g-1][b].pos,&groups[g],cand[g][c].f,cand[g][c].pos,rest);
                    /* Keys held from further back along this path (a bass under a figure, ringing arpeggio notes). */
                    int cb=b; for(long q=(long)g-2,depth=0;q>=0 && depth<4;q--,depth++) { cb=from[q+1][cb]; if(cb<0) break; v+=held_conflict(&groups[q],cand[q][cb].f,&groups[g],cand[g][c].f); }
                    /* The same finger on another key two quick notes apart (1-5-1-5 hopping under a pedal tone) and a hand
                       that drifts from where it was two notes ago: the hand should stay in position. */
                    if(g>=2 && groups[g].onset-groups[g-2].onset<=1.0+1e-9) { int a2=from[g-1][b];
                        if(a2>=0) { v+=.1*fabs(cand[g][c].pos-cand[g-2][a2].pos);
                            if(groups[g-2].k==1 && groups[g].k==1 && cand[g-2][a2].f[0]==cand[g][c].f[0] && groups[g-2].midi[0]!=groups[g].midi[0]) v+=2.5; } }
                    /* Crossings close together (1-3-1-3…) leave the thumb no time to come back:
                       the step before costs 4 more, the one before that 3. */
                    if(g>=2 && !rest && crossing(p,cand[g-1][b].f,&groups[g],cand[g][c].f)) {
                        int a2=from[g-1][b];
                        /* The crossing finger was down two notes ago (1-3-1, 3-1-3): the thumb had one note to travel. */
                        if(a2>=0 && groups[g-2].k==1 && groups[g].k==1 && cand[g-2][a2].f[0]==cand[g][c].f[0] && groups[g-2].midi[0]!=groups[g].midi[0]) v+=3;
                        if(a2>=0 && crossing(&groups[g-2],cand[g-2][a2].f,p,cand[g-1][b].f)) v+=4;
                        else if(a2>=0 && g>=3 && from[g-2][a2]>=0 && crossing(&groups[g-3],cand[g-3][from[g-2][a2]].f,&groups[g-2],cand[g-2][a2].f)) v+=3;
                    }
                    if(v<low) { low=v; from[g][c]=b; }
                }
                best[g][c]+=low;
            }
        }
        int c=0; for(int b=1;b<candCount[groupCount-1];b++) if(best[groupCount-1][b]<best[groupCount-1][c]) c=b;
        for(size_t g=groupCount;g-->0;) {
            for(int s=0;s<groups[g].k;s++) fingers[groups[g].index[s]]=cand[g][c].f[s];
            if(g) c=from[g][c]; if(c<0) c=0;
        }
        /* Equal pitches merged above share the finger of the kept one. */
        for(size_t i=0;i<n;i++) if(!fingers[order[i]]) for(size_t j=0;j<n;j++)
            if(fingers[order[j]] && events[order[j]].midi==events[order[i]].midi && fabs(events[order[j]].beat-events[order[i]].beat)<.03) { fingers[order[i]]=fingers[order[j]]; break; }
    }
    free(cand); free(candCount); free(best); free(from); free(order); free(groups);
}

void kv_finger_performance(const KvPerformance *p, unsigned char *fingers) {
    if(!p || !fingers) return;
    memset(fingers,0,p->count);
    kv_finger_events(p->events,p->count,0,fingers); kv_finger_events(p->events,p->count,1,fingers);
}
