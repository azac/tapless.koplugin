/* In-memory recognition experiment. No Lua callbacks, dictionary I/O or UI.
 * Floating-point order, candidate insertion and scoring follow 0.5.3.
 * Scratch storage is owned by Lua FFI. */
#include "core.h"
#include "scan.h"
#include "shape.h"
#include "engine.h"
#include <math.h>
#include <string.h>
#include <time.h>

typedef struct {
    char signature[65]; int length,valid;
    double x[64],y[64],length_value,scale;
} Ideal;
typedef struct {
    const char *signature; int length,flags,positions[65]; double score;
} Dynamic;
struct TEWorkspace {
    TCGesture g;
    unsigned char letters[513],lending[513],adjacent[676],near_present[26],valid[513],center_valid[26];
    double weights[513],prefix[513],px[513],py[513],cx[26],cy[26],cs[26],distances[513*26];
    int next[514*26],near_next[514*26];
    double cumulative[4096],actual_x[64],actual_y[64],actual_length;
    int has_actual,near,geometry_generation,old_samples;
    TSShapeCenter old_centers[26];
    Ideal ideals[128]; int ideal_next,ideal_count;
    Dynamic dynamics[256]; int dynamic_count;
    TECandidate shortlist[64],results[64]; int short_count,result_count;
};
int te_abi_version(void) { return 1; }
int te_request_size(void) { return sizeof(TERequest); }
int te_group_size(void) { return sizeof(TEGroup); }
int te_output_size(void) { return sizeof(TEOutput); }
int te_workspace_size(void) { return sizeof(TEWorkspace); }
static double maximum(double a,double b) { return a>b ? a:b; }
static double minimum(double a,double b) { return a<b ? a:b; }
static double distance(double ax,double ay,double bx,double by) {
    double dx=ax-bx,dy=ay-by; return sqrt(dx*dx+dy*dy);
}
static double now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC,&t)!=0) return 0;
    return (double)t.tv_sec*1000+(double)t.tv_nsec/1000000;
}
static int same_word(TERequest *r,TECandidate a,TECandidate b) {
    TSShapeEntry *x=&r->groups[a.group].shapes[a.index],*y=&r->groups[b.group].shapes[b.index];
    return x->word_length==y->word_length && memcmp(x->word,y->word,x->word_length)==0;
}
static void insert(TERequest *r,TECandidate *list,int *count,int keep,TECandidate hit) {
    for (int i=0;i<*count;++i) if (same_word(r,list[i],hit)) return;
    int position=*count;
    while (position>0 && hit.ranked<list[position-1].ranked) --position;
    if (position>=keep) return;
    int last=*count<keep ? *count:keep-1;
    for (int i=last;i>position;--i) list[i]=list[i-1];
    list[position]=hit; if (*count<keep) ++*count;
}
static void prepare(TEWorkspace *w,TERequest *r) {
    TCGesture *g=&w->g; int n=r->length;
    g->size=n;g->near_limit=r->near_limit;
    g->first_cost=r->first_cost;g->start_cost=r->start_cost;g->end_cost=r->end_cost;g->near_cost=r->near_cost;
    g->letters=w->letters;g->lending=w->lending;g->adjacent=w->adjacent;g->near_present=w->near_present;
    g->weights=w->weights;g->prefix=w->prefix;g->px=w->px;g->py=w->py;
    g->cx=w->cx;g->cy=w->cy;g->cs=w->cs;g->point_valid=w->valid;g->center_valid=w->center_valid;
    g->next=w->next;g->near_next=w->near_next;g->distances=w->distances;
    memset(w->valid,0,sizeof(w->valid));memset(w->adjacent,0,sizeof(w->adjacent));
    memset(w->near_present,0,sizeof(w->near_present));w->prefix[0]=0;w->near=0;
    int centers=0;
    for (int c=0;c<26;++c) {
        TSShapeCenter v=r->centers[c];w->center_valid[c]=v.present;
        w->cx[c]=v.x;w->cy[c]=v.y;w->cs[c]=v.size;centers+=v.present!=0;
    }
    for (int p=1;p<=n;++p) {
        w->letters[p]=r->signature[p-1]-97;w->weights[p]=r->weights[p];
        w->prefix[p]=w->prefix[p-1]+w->weights[p];
        w->lending[p]=r->observed[p] && fabs(r->turns[p])>=r->min_turn;
        if (w->lending[p] && centers && r->has_observations) w->near=1;
        if (r->has_letter_points && r->letter_points[p].present) {
            w->valid[p]=1;w->px[p]=r->letter_points[p].x;w->py[p]=r->letter_points[p].y;
        }
    }
    if (r->has_letter_points && r->has_endpoint) {
        w->valid[0]=1;w->px[0]=r->letter_points[0].x;w->py[0]=r->letter_points[0].y;
    }
    if (w->near) for (int a=0;a<26;++a) if (r->centers[a].present) {
        double reach=r->near_reach*maximum(1,r->centers[a].size);
        for (int b=0;b<26;++b) if (a!=b && r->centers[b].present &&
            distance(r->centers[a].x,r->centers[a].y,r->centers[b].x,r->centers[b].y)<=reach)
            w->adjacent[a*26+b]=1;
    }
    for (int c=0;c<26;++c) { w->next[(n+1)*26+c]=n+1;w->near_next[(n+1)*26+c]=n+1; }
    for (int p=n;p>=1;--p) {
        for (int c=0;c<26;++c) {
            w->next[p*26+c]=w->next[(p+1)*26+c];
            w->near_next[p*26+c]=w->near_next[(p+1)*26+c];
            if (w->near && w->lending[p] && w->adjacent[w->letters[p]*26+c]) {
                w->near_next[p*26+c]=p;w->near_present[c]=1;
            }
        }
        w->next[p*26+w->letters[p]]=p;
    }
    tc_init_distances(g);
    int changed=w->old_samples!=r->samples || !w->geometry_generation;
    for (int c=0;c<26;++c) {
        TSShapeCenter a=w->old_centers[c],b=r->centers[c];
        if (a.present!=b.present || (b.present && (a.x!=b.x || a.y!=b.y || a.size!=b.size))) changed=1;
        w->old_centers[c]=b;
    }
    if (changed) {
        w->old_samples=r->samples;w->geometry_generation=1;w->ideal_count=w->ideal_next=0;
        for (int i=0;i<r->group_count;++i) for (int j=0;j<r->groups[i].count;++j)
            r->groups[i].shapes[j].measured=0;
    }
    w->has_actual=0;
    int first=0,last=r->point_count-1,marked_first=-1,marked_last=-1;
    for (int i=0;i<r->point_count;++i) if (r->points[i].letter) { if (marked_first<0) marked_first=i;marked_last=i; }
    if (marked_first>=0) { first=marked_first;last=marked_last; }
    if (last-first<1) return;
    w->cumulative[first]=0;
    for (int i=first+1;i<=last;++i)
        w->cumulative[i]=w->cumulative[i-1]+distance(r->points[i-1].x,r->points[i-1].y,r->points[i].x,r->points[i].y);
    w->actual_length=w->cumulative[last];if (w->actual_length<=0) return;
    int segment=first+1;
    for (int i=0;i<r->samples;++i) {
        double target=w->actual_length*i/(r->samples-1);
        while (segment<last && w->cumulative[segment]<target) ++segment;
        double previous=w->cumulative[segment-1],length=w->cumulative[segment]-previous;
        double ratio=length>0 ? (target-previous)/length:0;
        w->actual_x[i]=r->points[segment-1].x+(r->points[segment].x-r->points[segment-1].x)*ratio;
        w->actual_y[i]=r->points[segment-1].y+(r->points[segment].y-r->points[segment-1].y)*ratio;
    }
    w->has_actual=1;
}
static int short_endpoint(TEWorkspace *w,const char *word,int length) {
    int n=w->g.size;if (length>4 || n<length || n>10 || !n || !length || w->letters[1]!=word[0]-97) return -1;
    int cursor=1,matched=0,last=0;
    for (int i=0;i<length;++i) for (int j=cursor;j<=n;++j) if (w->letters[j]==word[i]-97) { ++matched;last=j;cursor=j+1;break; }
    int missing=length-matched,trailing=n-(last ? last:n);
    if (missing>1 || trailing>1) return -1;
    int score=n/2+missing*3+trailing*2-2;return score>0 ? score:0;
}
static double finish(TEWorkspace *w,TERequest *r,TCScanEntry *e,double *score,int *positions) {
    if (e->length<=3 || (e->length==4 && e->frequency>=6500)) {
        int endpoint=short_endpoint(w,e->word,e->length);
        if (endpoint>=0) *score=minimum(*score,maximum(endpoint,*score-1));
    }
    int gap=r->length-e->length;if (gap<0) gap=-gap;
    if (gap<=r->scoring.edit_limit && *score>r->length/2+gap) {
        int edit=tc_edit_distance(r->signature,r->length,e->word,e->length,r->scoring.edit_limit);
        if (edit<=r->scoring.edit_limit) *score=minimum(*score,edit+r->length/2);
    }
    double repeat=0;
    for (int j=0;j<e->repeat_count;++j) {
        int position=positions[e->repeats[j].position];
        if (position) repeat=repeat+r->scoring.repeat_confidence[position]*minimum(2,e->repeats[j].count);
    }
    return *score*r->scoring.score_unit-e->frequency-e->context_bonus-floor(repeat*r->scoring.repeat_bonus);
}
static int dynamic(TCContext *context,TEWorkspace *w,TERequest *r,TECandidate *hit,int omission,TEOutput *out) {
    TCScanEntry *e=&r->groups[hit->group].scores[hit->index];
    int flags=hit->start+hit->end*2+hit->near*4+omission*8;
    Dynamic *cached=0;
    for (int i=0;i<w->dynamic_count;++i) {
        Dynamic *p=&w->dynamics[i];
        if (p->flags==flags && p->length==e->length && memcmp(p->signature,e->word,e->length)==0) { cached=p;break; }
    }
    int positions[65];TCResult result;
    if (!cached) {
        memset(positions,0,sizeof(positions));result.score=1000+e->length*20;
        if (r->has_letter_points && !r->has_endpoint && w->valid[r->length]) {
            w->valid[0]=1;w->px[0]=w->px[r->length];w->py[0]=w->py[r->length];
            for (int c=0;c<26;++c) w->distances[c]=-1;
        }
        if (!omission || tc_can_finish(&w->g,e->word,e->length,hit->start,hit->end,hit->near,0)) {
            if (!tc_align(context,&w->g,e->word,e->length,hit->start,hit->end,hit->near,0,0,r->has_letter_points,positions,&result)) return 0;
            ++out->dynamic_calls;
        }
        if (omission && result.score>=1000) {
            if (!tc_align(context,&w->g,e->word,e->length,hit->start,hit->end,hit->near,1,r->missing_cost,r->has_letter_points,positions,&result)) return 0;
            ++out->dynamic_calls;
        }
        if (w->dynamic_count<256) {
            cached=&w->dynamics[w->dynamic_count++];cached->signature=e->word;cached->length=e->length;
            cached->flags=flags;cached->score=result.score;memcpy(cached->positions,positions,sizeof(positions));
        }
    }
    double score=cached ? cached->score:result.score;
    hit->ranked=finish(w,r,e,&score,cached ? cached->positions:positions);hit->spatial=score;
    return 1;
}
static int ideal(TEWorkspace *w,TERequest *r,TCScanEntry *e,Ideal **result) {
    for (int i=0;i<w->ideal_count;++i) if (w->ideals[i].length==e->length &&
        memcmp(w->ideals[i].signature,e->word,e->length)==0) { *result=&w->ideals[i];return (*result)->valid; }
    Ideal *p=&w->ideals[w->ideal_next];w->ideal_next=(w->ideal_next+1)%128;
    if (w->ideal_count<128) ++w->ideal_count;
    memcpy(p->signature,e->word,e->length);p->length=e->length;p->valid=0;*result=p;
    if (e->length<2) return 0;
    double cumulative[65];cumulative[0]=0;double size=0;
    for (int i=0;i<e->length;++i) {
        int c=e->word[i]-97;if (!r->centers[c].present) return 0;
        size=size+maximum(1,r->centers[c].size);
        if (i>0) { int a=e->word[i-1]-97;cumulative[i]=cumulative[i-1]+distance(r->centers[a].x,r->centers[a].y,r->centers[c].x,r->centers[c].y); }
    }
    p->length_value=cumulative[e->length-1];p->scale=size/e->length;if (p->length_value<=0) return 0;
    int segment=1;
    for (int i=0;i<r->samples;++i) {
        double target=p->length_value*i/(r->samples-1);
        while (segment<e->length-1 && cumulative[segment]<target) ++segment;
        double previous=cumulative[segment-1],length=cumulative[segment]-previous;
        double ratio=length>0 ? (target-previous)/length:0;
        TSShapeCenter a=r->centers[e->word[segment-1]-97],b=r->centers[e->word[segment]-97];
        p->x[i]=a.x+(b.x-a.x)*ratio;p->y[i]=a.y+(b.y-a.y)*ratio;
    }
    p->valid=1;return 1;
}
static void rerank(TEWorkspace *w,TERequest *r,TECandidate *list,int *count,int limit,double weight) {
    double scores[64],total=0;int valid[64],scored=0;
    for (int i=0;i<*count;++i) {
        valid[i]=0;Ideal *p;
        if (w->has_actual && ideal(w,r,&r->groups[list[i].group].scores[list[i].index],&p)) {
            double distances=0;
            for (int j=0;j<r->samples;++j) distances=distances+distance(w->actual_x[j],w->actual_y[j],p->x[j],p->y[j]);
            double shape=distances/r->samples/p->scale;
            double length=minimum(r->geometry_max,fabs(w->actual_length-p->length_value)/maximum(p->scale,p->length_value));
            scores[i]=minimum(r->geometry_max,shape*0.85+length*0.15);valid[i]=1;total=total+scores[i];++scored;
        }
    }
    if (scored>=2) {
        for (int i=0;i<*count;++i) {
            list[i].geometry=valid[i] ? scores[i]:total/scored;list[i].has_geometry=1;
            list[i].ranked=list[i].ranked+floor(list[i].geometry*weight+0.5);
        }
        for (int i=1;i<*count;++i) { TECandidate h=list[i];int j=i;
            while (j>0 && h.ranked<list[j-1].ranked) { list[j]=list[j-1];--j; }list[j]=h;
        }
    }
    if (*count>limit) *count=limit;
}
static int choose_gate(TEWorkspace *w,TERequest *r,TSShapeState *s,TEOutput *out) {
    TEGate *g=&out->gate;TECandidate *list=w->results;int count=w->result_count;
    if (count<2 || !list[0].has_geometry || !list[1].has_geometry) { g->reason=3;return 0; }
    TECandidate best=list[0];g->has_choice=1;g->group=best.group;g->index=best.index;g->length=r->groups[best.group].scores[best.index].length;
    g->shape=best.geometry;g->spatial=best.spatial/maximum(1,r->length);g->margin=list[1].ranked-best.ranked;
    TECandidate alt[64];memcpy(alt,list,count*sizeof(TECandidate));
    int shape_active=r->shape_trigger;
    for (int i=0;i<count;++i) {
        if (!list[i].has_geometry) { g->reason=4;return 0; }
        if (shape_active) alt[i].ranked=alt[i].ranked+alt[i].spatial*(r->alignment_weight-r->scoring.score_unit)
            -floor(alt[i].geometry*r->geometry_weight+0.5)+floor(alt[i].geometry*s->shape_weight+0.5);
    }
    for (int i=1;i<count;++i) { TECandidate h=alt[i];int j=i;
        while (j>0 && h.ranked<alt[j-1].ranked) { alt[j]=alt[j-1];--j; }alt[j]=h;
    }
    g->stable=same_word(r,alt[0],best);g->alt_margin=alt[1].ranked-alt[0].ranked;
    if (!g->stable) g->reason=5;
    else if (g->length<r->gate_min_length) g->reason=6;
    else if (g->shape>r->gate_shape) g->reason=7;
    else if (g->spatial>r->gate_spatial) g->reason=8;
    else if (minimum(g->margin,g->alt_margin)<r->gate_margin) g->reason=9;
    else { memcpy(list,alt,count*sizeof(TECandidate));g->reason=10;g->accepted=1;return 1; }
    return 0;
}
static int shortlist(TCContext *context,TEWorkspace *w,TERequest *r,TEOutput *out,int keep) {
    w->result_count=0;
    for (int i=0;i<w->short_count;++i) {
        TECandidate hit=w->shortlist[i];hit.has_geometry=0;
        if (!dynamic(context,w,r,&hit,0,out)) return 0;
        if (hit.spatial<=maximum(6,r->length)) insert(r,w->results,&w->result_count,keep,hit);
    }
    return 1;
}
static void scan(TEWorkspace *w,TERequest *r,TEScan plan,TEOutput *out,int keep) {
    TEGroup *group=&r->groups[plan.group];TCScanPolicy policy=r->scoring;
    if (!r->has_endpoint) { w->valid[0]=0;for (int c=0;c<26;++c) w->distances[c]=-1; }
    policy.start=plan.start;policy.end=plan.end;policy.near=w->near;
    policy.points=r->has_letter_points;policy.has_next=1;
    ++out->scan_calls;out->scan_words+=group->count;
    for (int i=0;i<group->count;++i) {
        TCScanResult result;tc_scan(&w->g,r->signature,r->length,&group->scores[i],1,&policy,&result);
        if (result.spatial<=maximum(6,r->length)) {
            TECandidate hit={plan.group,i,plan.start,plan.end,result.used_near,0,result.spatial,result.ranked,0};
            insert(r,w->shortlist,&w->short_count,keep,hit);
        }
    }
}
static int shape_group(TERequest *r,TSShapeState *s,int id,int primary,double deadline,TEOutput *out) {
    if (id<0) return 1;
    TEGroup *g=&r->groups[id];int offset=0;
    while (offset<g->count) {
        if (s->entries>=s->max_entries || s->exhausted || (!primary && s->entries%32==0 && deadline>=0 && now_ms()>=deadline)) { s->exhausted=1;break; }
        int count=primary ? g->count-offset:(g->count-offset<32-s->entries%32 ? g->count-offset:32-s->entries%32);
        int processed=ts_shape_scan(s,g->shapes+offset,count,id,offset);++out->shape_calls;
        if (s->overflow) return 0;
        offset+=processed;if (!processed) break;
    }
    return 1;
}
int te_run(TCContext *context,TEWorkspace *w,TERequest *r,TSShapeState *s,TEOutput *out) {
    if (!context || !w || !r || !s || !out || r->length<1 || r->length>512 || r->point_count<0 || r->point_count>4096 ||
        r->limit<1 || r->limit>16 || r->samples<2 || r->samples>64 || s->keep<1 || s->keep>32 || r->near_limit<0 || r->near_limit>32) return 0;
    memset(out,0,sizeof(*out));w->dynamic_count=w->short_count=w->result_count=0;
    prepare(w,r);int sk=maximum(40,r->limit),fk=maximum(12,r->limit),at=0;
    /* The first endpoint pair is marked by phase=0; all other scans phase=1. */
    while (at<r->scan_count && r->scans[at].fallback==0) scan(w,r,r->scans[at++],out,sk);
    TEGate *gate=&out->gate;gate->enabled=r->gate_enabled;
    if (r->gate_enabled) {
        if (r->point_count<2 || r->length<r->gate_min_length) gate->reason=1;
        else {
            gate->has_boundary=1;int a=r->signature[0]-97,b=r->signature[r->length-1]-97;
            gate->start=r->centers[a].present ? distance(r->points[0].x,r->points[0].y,r->centers[a].x,r->centers[a].y)/maximum(1,r->centers[a].size):INFINITY;
            gate->endpoint=r->has_endpoint && r->centers[b].present ? distance(r->letter_points[0].x,r->letter_points[0].y,r->centers[b].x,r->centers[b].y)/maximum(1,r->centers[b].size):INFINITY;
            if (gate->start>r->gate_boundary || gate->endpoint>r->gate_boundary) gate->reason=2;
            else {
                gate->attempted=1;if (!shortlist(context,w,r,out,fk)) return 0;
                rerank(w,r,w->results,&w->result_count,fk,r->geometry_weight);
                if (choose_gate(w,r,s,out)) { out->count=w->result_count<r->limit ? w->result_count:r->limit;memcpy(out->hits,w->results,out->count*sizeof(TECandidate));return 1; }
            }
        }
    }
    while (at<r->scan_count && r->scans[at].fallback==1) scan(w,r,r->scans[at++],out,sk);
    if (!w->short_count) while (at<r->scan_count) scan(w,r,r->scans[at++],out,sk);
    if (!shortlist(context,w,r,out,fk)) return 0;
    int shape_active=0;
    if (r->shape_trigger && w->has_actual) {
        s->entries=s->compared=s->exhausted=s->count=s->overflow=0;
        s->samples=r->samples;s->length=w->actual_length;s->max_score=r->geometry_max;
        memcpy(s->centers,r->centers,sizeof(s->centers));
        for (int i=0;i<r->samples;++i) { s->x[i]=w->actual_x[i];s->y[i]=w->actual_y[i]; }
        if (++s->generation==0) { memset(s->words,0,s->capacity*sizeof(TSWordSlot));memset(s->signatures,0,s->capacity*sizeof(TSSignatureSlot));s->generation=1; }
        double deadline=r->shape_budget_ms<0 ? -1:now_ms()+r->shape_budget_ms;
        for (int i=0;i<r->pair_count;++i) {
            if ((deadline>=0 && now_ms()>=deadline) || s->exhausted) { s->exhausted=1;break; }
            int primary=out->shape_buckets==0;
            if (!shape_group(r,s,r->pairs[i].personal,primary,deadline,out)) return 0;
            if (!s->exhausted) { ++out->shape_buckets;if (!shape_group(r,s,r->pairs[i].normal,primary,deadline,out)) return 0; }
            if (s->exhausted) break;
        }
        out->shape_entries=s->entries;out->shape_compared=s->compared;out->shape_exhausted=s->exhausted;
        shape_active=s->count>0;
        for (int i=0;i<s->count;++i) {
            TSShapeHit h=s->hits[i];TECandidate hit={h.group,h.index,1,1,w->near,0,0,0,0};
            int seen=0;for (int j=0;j<w->result_count;++j) if (same_word(r,hit,w->results[j])) { seen=1;break; }
            if (!seen) { if (!dynamic(context,w,r,&hit,1,out)) return 0;
                if (hit.spatial<1000) insert(r,w->results,&w->result_count,fk+s->keep,hit);
            }
        }
        if (shape_active) for (int i=0;i<w->result_count;++i)
            w->results[i].ranked=w->results[i].ranked+w->results[i].spatial*(r->alignment_weight-r->scoring.score_unit);
    }
    if (w->result_count) {
        rerank(w,r,w->results,&w->result_count,r->limit,shape_active ? s->shape_weight:r->geometry_weight);
        out->count=w->result_count;memcpy(out->hits,w->results,out->count*sizeof(TECandidate));
    } else {
        out->fallback=1;out->count=w->short_count<r->limit ? w->short_count:r->limit;
        memcpy(out->hits,w->shortlist,out->count*sizeof(TECandidate));
    }
    return 1;
}
