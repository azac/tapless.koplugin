/* Translation of Tapless gesture_matcher.lua, preserving its
 * scoring rules and summation order. Not a clean-room rewrite.
 * No screen, input, file or settings access. */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "core.h"

typedef struct { int position, parent, taken; double cost; } Node;
struct TCContext { Node *nodes; int *frontiers; size_t node_capacity, frontier_capacity; };
TCContext *tc_new(void) { return calloc(1, sizeof(TCContext)); }
void tc_free(TCContext *c) { if (c) { free(c->nodes); free(c->frontiers); free(c); } }
void tc_init_distances(TCGesture *g) {
    for (int i = 0; i < (g->size + 1) * 26; ++i) g->distances[i] = -1;
}
static double distance_at(TCGesture *g, int code, int position) {
    if (!g->point_valid[position] || !g->center_valid[code]) return -1;
    double *value = &g->distances[position * 26 + code];
    if (*value < 0) {
        double x = g->px[position] - g->cx[code], y = g->py[position] - g->cy[code];
        *value = fmin(2, sqrt(x*x + y*y) / fmax(1, g->cs[code]));
    }
    return *value;
}
static void failed(int length, TCResult *out) {
    out->score = 1000 + length * 20; out->mismatch = out->omitted = 0;
}
int tc_can_finish(const TCGesture *g, const char *word, int length,
        int start, int end, int near, int reuse) {
    int size = g->size;
    if (!size || !length) return 0;
    if (reuse) {
        if (g->next[26 + word[0]-97] > size && !start) return 0;
        if (g->next[26 + word[length-1]-97] > size && !end) return 0;
        int required = 0;
        for (int i=1; i<length-1; ++i) if (g->next[26 + word[i]-97] > size) {
            if (!near || !g->near_present[word[i]-97]) return 0;
            if (++required > g->near_limit) return 0;
        }
        return 1;
    }
    int budget = near ? g->near_limit : 0, a[33], b[33], *prev=a, *cur=b;
    for (int j=0; j<=budget; ++j) prev[j]=0;
    for (int i=0; i<length; ++i) {
        int code=word[i]-97;
        for (int j=0; j<=budget; ++j) {
            int minimum=prev[j]+1;
            int pos=minimum<=size ? g->next[minimum*26+code] : size+1;
            if (i==0 && start && length>1 && size>1) pos=1;
            if (i==length-1 && end && minimum<=size) pos=pos<size ? pos : size;
            if (near && i>0 && i<length-1 && j>0) {
                int from=prev[j-1]+1;
                int borrowed=from<=size ? g->near_next[from*26+code] : size+1;
                if (borrowed<pos) pos=borrowed;
            }
            cur[j]=pos;
        }
        int *swap=prev; prev=cur; cur=swap;
        if (prev[budget]>size) return 0;
    }
    return 1;
}
void tc_greedy(TCGesture *g, const char *word, int length, int start, int end,
        int near, int budget, int points, int has_next, int *positions, TCResult *out) {
    int size=g->size;
    memset(positions, 0, (length+1)*sizeof(int)); failed(length,out);
    if (!size || !length) return;
    int cursor=1, accepted=0, borrowed=0, slipped_start=0, slipped_end=0;
    int first=0,last=0,measured=0; double geometry=0;
    for (int i=0; i<length; ++i) {
        int code=word[i]-97, pos=has_next && cursor<=size ? g->next[cursor*26+code] : size+1;
        if (pos>size) pos=0;
        if (i==0 && start && length>1 && size>1 && g->letters[1]!=code) { pos=1; slipped_start=1; }
        if (!pos && near && borrowed<budget && i>0 && i<length-1) {
            pos=cursor<=size ? g->near_next[cursor*26+code] : size+1;
            if (pos>size) pos=0; else ++borrowed;
        }
        int release=!pos && end && i==length-1 && size>0;
        if (release) { pos=size; slipped_end=1; }
        if (!pos) break;
        accepted=i+1; positions[i+1]=pos;
        if (!release && !first) first=pos;
        last=pos;
        if (points) {
            double value=distance_at(g,code,release ? 0 : pos);
            if (value>=0) { geometry+=value; ++measured; }
        }
        cursor=pos+1;
    }
    double score;
    if (accepted<length) score=1000+(length-accepted)*20;
    else {
        double skipped=0,leading=0,trailing=0; int matched=1;
        for (int pos=1; pos<=size; ++pos) {
            while (matched<=length && positions[matched] && positions[matched]<pos) ++matched;
            if (matched>length || positions[matched]!=pos) {
                double w=g->weights[pos]; skipped+=w;
                if (pos<(first ? first : 1)) leading+=w;
                if (pos>(last ? last : size)) trailing+=w;
            }
        }
        score=skipped+leading*2; score=score+trailing*2;
        if (slipped_start) score+=g->start_cost; else if (g->letters[1]!=word[0]-97) score+=g->first_cost;
        if (slipped_end) score+=g->end_cost; else if (g->letters[size]!=word[length-1]-97) score+=4;
        score=score+borrowed*g->near_cost;
    }
    if (measured>0) score=score+fmin(4,floor(geometry*2/measured+0.5));
    out->score=score; out->mismatch=slipped_end;
}
int tc_align(TCContext *c, TCGesture *g, const char *word, int length, int start,
        int end, int near, int has_omission, double omission, int points, int *positions, TCResult *out) {
    int n=g->size, limit=near ? g->near_limit : 0, stride=n+1;
    memset(positions,0,(length+1)*sizeof(int)); failed(length,out);
    if (!n || !length) return 1;
    size_t max_nodes=(size_t)length*n*(limit+1)+2, cells=(size_t)stride*(limit+1);
    if (max_nodes>c->node_capacity) {
        Node *next=realloc(c->nodes,max_nodes*sizeof(Node)); if (!next) return 0;
        c->nodes=next; c->node_capacity=max_nodes;
    }
    if (cells*2>c->frontier_capacity) {
        int *next=realloc(c->frontiers,cells*2*sizeof(int)); if (!next) return 0;
        c->frontiers=next; c->frontier_capacity=cells*2;
    }
    Node *nodes=c->nodes; int count=1, *prev=c->frontiers, *cur=prev+cells;
    memset(prev,0,cells*sizeof(int)); prev[0]=1; nodes[1]=(Node){0,0,0,0};
    for (int i=0; i<length; ++i) {
        int code=word[i]-97, inner=i>0 && i<length-1, allow_omission=inner && has_omission;
        double minima[33]; int origins[33];
        for (int a=0; a<=limit; ++a) { minima[a]=INFINITY; origins[a]=0; }
        memset(cur,0,cells*sizeof(int));
        for (int pos=1; pos<=n; ++pos) {
            for (int a=0; a<=limit; ++a) {
                int node=prev[a*stride+pos-1];
                if (node) {
                    double value=nodes[node].cost-g->prefix[pos-1];
                    if (value<minima[a]) { minima[a]=value; origins[a]=node; }
                }
            }
            int event=g->letters[pos]==code || (inner && near && g->near_next[pos*26+code]==pos)
                || (i==0 && start && length>1 && n>1 && pos==1) || (i==length-1 && end && pos==n);
            if (allow_omission) for (int a=0; a<=limit; ++a) if (prev[a*stride+pos]) event=1;
            if (!event) continue;
            int slipped=i==0 && start && pos==1 && length>1 && n>1 && g->letters[pos]!=code;
            int release=i==length-1 && end && pos==n && g->letters[pos]!=code;
            int exact=g->letters[pos]==code || slipped || release;
            int borrowed=near && inner && g->letters[pos]!=code && g->lending[pos]
                && g->adjacent[g->letters[pos]*26+code];
            double geometry=-1;
            if ((exact || borrowed) && points) {
                geometry=distance_at(g,code,release ? 0 : pos);
                if (geometry>=0) geometry=geometry*2/length;
            }
            for (int a=0; a<=limit; ++a) {
                double score=INFINITY; int parent=0,taken=0;
                int source=exact ? a : borrowed && a>0 ? a-1 : -1;
                if (source>=0 && origins[source]) {
                    parent=origins[source]; taken=1;
                    if (i==0) {
                        score=g->prefix[pos-1]*3;
                        if (g->letters[1]!=code) score+=slipped ? g->start_cost : g->first_cost;
                    } else score=minima[source]+g->prefix[pos-1];
                    if (borrowed) score+=g->near_cost;
                    if (geometry>=0) score+=geometry;
                }
                int omitted=allow_omission ? prev[a*stride+pos] : 0;
                if (omitted && nodes[omitted].cost+omission<score) {
                    score=nodes[omitted].cost+omission; parent=omitted; taken=0;
                }
                if (parent) { ++count; nodes[count]=(Node){pos,parent,taken,score}; cur[a*stride+pos]=count; }
            }
        }
        int *swap=prev; prev=cur; cur=swap;
    }
    double best=INFINITY; int final=0,final_pos=0,final_allowance=0;
    for (int a=0; a<=limit; ++a) for (int pos=1; pos<=n; ++pos) {
        int node=prev[a*stride+pos]; if (!node) continue;
        double score=nodes[node].cost+(g->prefix[n]-g->prefix[pos])*3;
        if (score<best || (score==best && (pos<final_pos || (pos==final_pos && a<final_allowance)))) {
            best=score; final=node; final_pos=pos; final_allowance=a;
        }
    }
    if (!final) return 1;
    int omitted=0;
    for (int i=length; i>=1; --i) {
        if (nodes[final].taken) positions[i]=nodes[final].position; else ++omitted;
        final=nodes[final].parent;
    }
    int mismatch=g->letters[final_pos]!=word[length-1]-97;
    if (mismatch) best+=g->end_cost; else if (g->letters[n]!=word[length-1]-97) best+=4;
    out->score=best; out->mismatch=mismatch; out->omitted=omitted;
    return 1;
}

int tc_abi_version(void) { return 1; }
int tc_gesture_size(void) { return sizeof(TCGesture); }
int tc_result_size(void) { return sizeof(TCResult); }
