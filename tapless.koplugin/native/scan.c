/* Experimental batch translation of scoring.lua.
 * Inputs validated by scan_matcher.lua: <=512 observations, <=64 word bytes,
 * lowercase ASCII, edit limit <=32. No callbacks or UI/input access. */
#include <math.h>
#include "core.h"
#include "scan.h"

int tc_scan_version(void) { return 1; }
int tc_scan_entry_size(void) { return sizeof(TCScanEntry); }
int tc_scan_policy_size(void) { return sizeof(TCScanPolicy); }
int tc_scan_result_size(void) { return sizeof(TCScanResult); }

int tc_edit_distance(const char *left, int n, const char *right, int m, int limit) {
    int infinity=limit+1;
    if (n-m>limit || m-n>limit) return infinity;
    int a[65], b[65], *previous=a, *current=b;
    for (int j=0;j<=m;++j) previous[j]=j<=limit ? j : infinity;
    for (int i=1;i<=n;++i) {
        int from=i-limit>1 ? i-limit : 1, to=i+limit<m ? i+limit : m;
        for (int j=0;j<=m;++j) current[j]=infinity;
        current[0]=i<=limit ? i : infinity;
        int minimum=current[0];
        for (int j=from;j<=to;++j) {
            int v=previous[j]+1, insertion=current[j-1]+1;
            int substitution=previous[j-1]+(left[i-1]!=right[j-1]);
            if (insertion<v) v=insertion;
            if (substitution<v) v=substitution;
            if (v>infinity) v=infinity;
            current[j]=v;
            if (v<minimum) minimum=v;
        }
        if (minimum>limit) return infinity;
        int *swap=previous; previous=current; current=swap;
    }
    return previous[m];
}

static int short_endpoint(const TCGesture *g, const char *word, int length) {
    if (length>4 || g->size<length || g->size>10 || !g->size
            || !length || g->letters[1]!=word[0]-97) return -1;
    int cursor=1, matched=0, last=0;
    for (int i=0;i<length;++i) {
        for (int j=cursor;j<=g->size;++j) if (g->letters[j]==word[i]-97) {
            ++matched; last=j; cursor=j+1; break;
        }
    }
    int missing=length-matched, trailing=g->size-(last ? last : g->size);
    if (missing>1 || trailing>1) return -1;
    int score=g->size/2+missing*3+trailing*2-2;
    return score>0 ? score : 0;
}

void tc_scan(TCGesture *g, const char *signature, int signature_length,
        const TCScanEntry *entries, int count, const TCScanPolicy *policy, TCScanResult *results) {
    int a[65], b[65];
    for (int index=0;index<count;++index) {
        const TCScanEntry *entry=&entries[index];
        TCScanResult *output=&results[index];
        output->spatial=output->ranked=INFINITY; output->used_near=0;
        if (!entry->enabled) continue;
        const char *word=entry->word; int length=entry->length;
        TCResult plain;
        tc_greedy(g,word,length,policy->start,policy->end,policy->near,0,
            policy->points,policy->has_next,a,&plain);
        double score=plain.score; int *positions=a;
        if (score>=1000 && policy->near
                && tc_can_finish(g,word,length,policy->start,policy->end,1,1)) {
            TCResult neighbour;
            tc_greedy(g,word,length,policy->start,policy->end,1,g->near_limit,
                policy->points,policy->has_next,b,&neighbour);
            if (neighbour.score<score) {
                score=neighbour.score; positions=b; output->used_near=1;
            }
        }
        if (length<=3 || (length==4 && entry->frequency>=6500)) {
            int endpoint=short_endpoint(g,word,length);
            if (endpoint>=0) score=fmin(score,fmax(endpoint,score-1));
        }
        int gap=signature_length-length; if (gap<0) gap=-gap;
        if (gap<=policy->edit_limit && score>signature_length/2+gap) {
            int edit=tc_edit_distance(signature,signature_length,word,length,policy->edit_limit);
            if (edit<=policy->edit_limit) score=fmin(score,edit+signature_length/2);
        }
        double repeat=0;
        for (int j=0;j<entry->repeat_count;++j) {
            const TCScanRepeat *r=&entry->repeats[j];
            int position=positions[r->position];
            if (position) repeat+=policy->repeat_confidence[position]*fmin(2,r->count);
        }
        output->spatial=score;
        output->ranked=score*policy->score_unit-entry->frequency-entry->context_bonus
            -floor(repeat*policy->repeat_bonus);
    }
}
