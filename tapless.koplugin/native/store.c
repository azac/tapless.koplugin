/* Lazy native dictionary storage. Same TSV/index order as DictionaryIndex.
 * All owned strings remain valid until td_free; no borrowed Lua pointers persist. */
#include "core.h"
#include "scan.h"
#include "shape.h"
#include "engine.h"
#include "store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <time.h>

typedef struct { long offset; size_t bytes; int present; } Meta;
typedef struct {
    char *word,*base,*gesture,*lang;
    TCScanRepeat *repeats;
    int length,base_length,repeat_count,enabled;
    double frequency;
} Record;
typedef struct Group {
    TEGroup g;
    Record **refs;
    unsigned int generation;
    unsigned int geometry;
    int multiple_repeats;
} Group;
typedef struct {
    char *data;
    Record *records;
    int count,ready;
    Group groups[65];
} Bucket;
struct TDStore {
    FILE *data,*popular;
    Meta index[676],popular_index[26];
    Bucket buckets[676],popular_buckets[26];
    Group fallback[26];
    char *dictionary,*language;
    char *context_words[256];
    double context_bonuses[256];
    int context_slots[512],context_count;
    unsigned int generation;
    unsigned int geometry;
    TSShapeCenter centers[26];
    int samples;
};
int td_abi_version(void) { return 2; }
static char *copy_string(const char *s) {
    size_t n=strlen(s)+1; char *p=malloc(n); if (p) memcpy(p,s,n); return p;
}
static double now_ms(int cpu) {
    struct timespec t;
    if (clock_gettime(cpu ? CLOCK_PROCESS_CPUTIME_ID:CLOCK_MONOTONIC,&t)) return 0;
    return (double)t.tv_sec*1000+(double)t.tv_nsec/1000000;
}
static unsigned int hash_word(const char *word) {
    unsigned int h=2166136261u;
    for (const unsigned char *p=(const unsigned char *)word;*p;++p) h=(h^*p)*16777619u;
    return h;
}
static void free_group(Group *g) {
    free(g->g.scores); free(g->g.shapes); free(g->refs); memset(g,0,sizeof(*g));
}
static void free_bucket(Bucket *b) {
    for (int i=0;i<65;++i) free_group(&b->groups[i]);
    for (int i=0;i<b->count;++i) { free(b->records[i].gesture); free(b->records[i].repeats); }
    free(b->records); free(b->data); memset(b,0,sizeof(*b));
}
void td_free(TDStore *s) {
    if (!s) return;
    for (int i=0;i<676;++i) free_bucket(&s->buckets[i]);
    for (int i=0;i<26;++i) { free_bucket(&s->popular_buckets[i]);free_group(&s->fallback[i]); }
    for (int i=0;i<s->context_count;++i) free(s->context_words[i]);
    if (s->data) fclose(s->data);
    if (s->popular) fclose(s->popular);
    free(s->dictionary);free(s->language);free(s);
}
static int index_file(const char *path, Meta *out, int key_length, FILE *data) {
    FILE *file=fopen(path,"rb"); if (!file) return 0;
    if (fseek(data,0,SEEK_END)) { fclose(file);return 0; }
    long size=ftell(data); if (size<0) { fclose(file);return 0; }
    char line[512];int found=0;
    while (fgets(line,sizeof(line),file)) {
        char key[3]; unsigned long numbers[3];
        size_t n=strlen(line);while (n && (line[n-1]=='\r'||line[n-1]=='\n')) line[--n]=0;
        if (n<(size_t)key_length+6 || line[key_length]!='\t') continue;
        int valid=1;for(int i=0;i<key_length;++i) if(line[i]<'a'||line[i]>'z') valid=0;
        memcpy(key,line,(size_t)key_length);key[key_length]=0;
        char *at=line+key_length+1;
        for(int i=0;i<3 && valid;++i) {
            unsigned long value=0;int digits=0;
            while (*at>='0'&&*at<='9') {
                unsigned int digit=(unsigned int)(*at++-'0');digits=1;
                if(value>(ULONG_MAX-digit)/10) { valid=0;break; }
                value=value*10+digit;
            }
            numbers[i]=value;
            if(!digits||(i<2?*at++!='\t':*at!=0)) valid=0;
        }
        if(!valid) continue;
        unsigned long offset=numbers[0],bytes=numbers[1];
        if(offset>INT_MAX||bytes>INT_MAX||offset>(unsigned long)size||bytes>(unsigned long)size-offset) {
            fclose(file);return 0;
        }
        int i=key[0]-'a';if (key_length==2) i=i*26+key[1]-'a';
        out[i]=(Meta){(long)offset,(size_t)bytes,1};++found;
    }
    int ok=!ferror(file);fclose(file);return ok && found>0;
}
TDStore *td_open(const char *data,const char *index,const char *popular_data,const char *popular_index,
        const char *dictionary,const char *language) {
    if (!data||!index||!dictionary||!language) return NULL;
    TDStore *s=calloc(1,sizeof(*s));if (!s) return NULL;
    s->dictionary=copy_string(dictionary);s->language=copy_string(language);s->generation=1;
    s->data=fopen(data,"rb");
    if (!s->dictionary||!s->language||!s->data||!index_file(index,s->index,2,s->data)) { td_free(s);return NULL; }
    if (popular_data && popular_index) {
        s->popular=fopen(popular_data,"rb");
        if (s->popular && !index_file(popular_index,s->popular_index,1,s->popular)) {
            fclose(s->popular);s->popular=NULL;
        }
    }
    return s;
}
static double bonus(TDStore *s,const char *word) {
    if (!s->context_count) return 0;
    unsigned int slot=hash_word(word)&511;
    for (int n=0;n<512 && s->context_slots[slot];++n,slot=(slot+1)&511) {
        int i=s->context_slots[slot]-1;
        if (!strcmp(s->context_words[i],word)) return s->context_bonuses[i];
    }
    return 0;
}
static int context(TDStore *s,const TDBonus *values,int count) {
    if (count<0||count>256||(count&&!values)) return 0;
    int same=count==s->context_count;
    for (int i=0;i<count;++i) {
        if (!values[i].word||strlen(values[i].word)>4096||!isfinite(values[i].bonus)) return 0;
        if (same && (values[i].bonus!=s->context_bonuses[i]||strcmp(values[i].word,s->context_words[i]))) same=0;
    }
    if (same) return 1;
    char *words[256]={0};
    for (int i=0;i<count;++i) if (!(words[i]=copy_string(values[i].word))) {
        for (int j=0;j<i;++j) free(words[j]);return 0;
    }
    for (int i=0;i<s->context_count;++i) free(s->context_words[i]);
    memset(s->context_slots,0,sizeof(s->context_slots));
    s->context_count=count;
    for (int i=0;i<count;++i) {
        s->context_words[i]=words[i];s->context_bonuses[i]=values[i].bonus;
        unsigned int slot=hash_word(words[i])&511;
        while (s->context_slots[slot]) slot=(slot+1)&511;
        s->context_slots[slot]=i+1;
    }
    if (++s->generation==0) {
        s->generation=1;
        for (int i=0;i<676;++i) for(int j=0;j<65;++j) s->buckets[i].groups[j].generation=0;
        for (int i=0;i<26;++i) {
            for(int j=0;j<65;++j) s->popular_buckets[i].groups[j].generation=0;
            s->fallback[i].generation=0;
        }
    }
    return 1;
}
static int read_bucket(TDStore *s,Bucket *b,FILE *file,Meta meta,TDStats *stats) {
    if (b->ready) return 1;
    if (!meta.present) { b->ready=1;return 1; }
    b->data=malloc(meta.bytes+1);if (!b->data) return 0;
    if (fseek(file,meta.offset,SEEK_SET)||fread(b->data,1,meta.bytes,file)!=meta.bytes) return 0;
    b->data[meta.bytes]=0;
    /* Embedded NUL cannot be represented by the existing Lua TSV/native bridge. */
    if (memchr(b->data,0,meta.bytes)) return 0;
    int capacity=0;
    for (char *line=b->data,*end=b->data+meta.bytes;line<end;) {
        char *next=memchr(line,'\n',(size_t)(end-line));if (next) *next++=0;else next=end;
        char *a=strchr(line,'\t'),*c=a?strchr(a+1,'\t'):NULL,*d=c?strchr(c+1,'\t'):NULL;
        if (!a||!c||!d||a==line||c==a+1||d==c+1||!d[1]||strchr(d+1,'\t')) { line=next;continue; }
        int valid=1;
        for (char *p=c+1;p<d;++p) if (*p<'0'||*p>'9') valid=0;
        for (char *p=d+1;*p;++p) if (*p<'a'||*p>'z') valid=0;
        if (!valid) { line=next;continue; }
        *a=*c=*d=0;
        size_t original=strlen(line);if (original>4096) return 0;
        for (size_t i=0;i<original;++i) if (line[i]<'a'||line[i]>'z') return 0;
        char collapsed[65];int n=0,repeat_count=0;TCScanRepeat repeats[64];
        for (size_t i=0;i<original;++i) {
            if (i && line[i]==line[i-1]) {
                if (repeat_count && repeats[repeat_count-1].position==n) repeats[repeat_count-1].count+=1;
                else repeats[repeat_count++]=(TCScanRepeat){n,1};
            } else { if (n==64) return 0;collapsed[n++]=line[i]; }
        }
        collapsed[n]=0;double freq=strtod(c+1,NULL);if (!isfinite(freq)) return 0;
        if (b->count==capacity) {
            int new_capacity=capacity?capacity*2:64;
            if (new_capacity>2000000) return 0;
            Record *records=realloc(b->records,(size_t)new_capacity*sizeof(*records));
            if (!records) return 0;b->records=records;capacity=new_capacity;
        }
        Record *r=&b->records[b->count++];memset(r,0,sizeof(*r));
        r->word=a+1;r->base=line;r->lang=d+1;r->length=n;r->base_length=(int)original;r->frequency=freq;
        r->gesture=copy_string(collapsed);if (!r->gesture) return 0;
        r->enabled=!strcmp(r->lang,s->dictionary)||!strcmp(r->lang,s->language);
        r->repeat_count=repeat_count;
        if (repeat_count) {
            r->repeats=malloc((size_t)repeat_count*sizeof(*r->repeats));if (!r->repeats) return 0;
            memcpy(r->repeats,repeats,(size_t)repeat_count*sizeof(*r->repeats));
        }
        line=next;
    }
    b->ready=1;if (stats) { ++stats->loaded;stats->entries+=b->count; }return 1;
}
static int fill_group(TDStore *s,Group *g,Record **refs,int count) {
    g->refs=refs;g->g.count=count;
    if (!count) return 1;
    g->g.scores=calloc((size_t)count,sizeof(*g->g.scores));g->g.shapes=calloc((size_t)count,sizeof(*g->g.shapes));
    if (!g->g.scores||!g->g.shapes) return 0;
    for (int i=0;i<count;++i) {
        Record *r=refs[i];TCScanEntry *v=&g->g.scores[i];TSShapeEntry *h=&g->g.shapes[i];
        if(r->repeat_count>=3) g->multiple_repeats=1;
        v->word=r->gesture;v->length=r->length;v->repeat_count=r->repeat_count;v->repeats=r->repeats;
        v->enabled=h->enabled=r->enabled;v->frequency=h->frequency=r->frequency;
        v->context_bonus=r->enabled?bonus(s,r->word):0;
        h->word=r->word;h->word_length=(int)strlen(r->word);h->signature=r->gesture;
        h->signature_length=r->length;h->minimum_length=r->base_length;
    }
    g->generation=s->generation;return 1;
}
static Group *bucket_group(TDStore *s,Bucket *b,int length) {
    if (length<0||length>64) return NULL;
    Group *g=&b->groups[length];if (g->refs||!b->count) return g;
    int count=0;for(int i=0;i<b->count;++i) if(!length||b->records[i].length==length) ++count;
    Record **refs=malloc((size_t)(count?count:1)*sizeof(*refs));if (!refs) return NULL;
    int j=0;for(int i=0;i<b->count;++i) if(!length||b->records[i].length==length) refs[j++]=&b->records[i];
    if (!fill_group(s,g,refs,count)) { free_group(g);return NULL; }return g;
}
static Group *resolve(TDStore *s,TDQuery q,TDStats *stats) {
    if (q.first<0||q.first>=26||q.last<0||q.last>=26||q.length<0||q.length>64) return NULL;
    if (q.kind==0) {
        int i=q.first*26+q.last;Bucket *b=&s->buckets[i];
        if (!read_bucket(s,b,s->data,s->index[i],stats)) { free_bucket(b);return NULL; }
        return bucket_group(s,b,q.length);
    }
    if (q.kind!=1) return NULL;
    if (s->popular) {
        Bucket *b=&s->popular_buckets[q.first];
        if (!read_bucket(s,b,s->popular,s->popular_index[q.first],stats)) { free_bucket(b);return NULL; }
        return bucket_group(s,b,0);
    }
    Group *g=&s->fallback[q.first];if (g->refs) return g;
    int count=0;
    for(int i=0;i<26;++i) {
        Bucket *b=&s->buckets[q.first*26+i];
        if (!read_bucket(s,b,s->data,s->index[q.first*26+i],stats)) { free_bucket(b);return NULL; }
        if (count>INT_MAX-b->count) return NULL;count+=b->count;
    }
    Record **refs=malloc((size_t)(count?count:1)*sizeof(*refs));if (!refs) return NULL;
    int at=0;for(int i=0;i<26;++i) {
        Bucket *b=&s->buckets[q.first*26+i];for(int j=0;j<b->count;++j) refs[at++]=&b->records[j];
    }
    if (!fill_group(s,g,refs,count)) { free_group(g);return NULL; }return g;
}
int td_run(TDStore *s,const TDQuery *queries,const TDBonus *bonuses,int count,
        TCContext *context_ptr,TEWorkspace *workspace,TERequest *r,TSShapeState *shape,TEOutput *out,TDStats *stats) {
    if (!s||!queries||!r||!r->groups||r->group_count<0||r->group_count>4096||!stats
            ||r->length<1||r->length>512||(r->has_observations&&!r->repeats)) return 0;
    memset(stats,0,sizeof(*stats));double wall=now_ms(0),cpu=now_ms(1);
    if (!context(s,bonuses,count)) return 0;
    int observed_repeat=0;
    if(r->has_observations) for(int i=1;i<=r->length;++i) if(r->repeats[i]!=0) observed_repeat=1;
    int changed=!s->geometry||s->samples!=r->samples;
    for(int i=0;i<26;++i) {
        TSShapeCenter a=s->centers[i],b=r->centers[i];
        if(a.present!=b.present||(b.present&&(a.x!=b.x||a.y!=b.y||a.size!=b.size))) changed=1;
        s->centers[i]=b;
    }
    s->samples=r->samples;
    if(changed && ++s->geometry==0) {
        s->geometry=1;
        for(int i=0;i<676;++i) for(int j=0;j<65;++j) s->buckets[i].groups[j].geometry=0;
        for(int i=0;i<26;++i) {
            for(int j=0;j<65;++j) s->popular_buckets[i].groups[j].geometry=0;
            s->fallback[i].geometry=0;
        }
    }
    for(int i=0;i<r->group_count;++i) {
        if (queries[i].kind==-1) continue;
        Group *g=resolve(s,queries[i],stats);if (!g) return 0;
        /* Lua pairs() can visit three or more sparse repeat positions in a
         * different order. floor(sum*4500) then differs by one at boundaries.
         * Preserve existing arithmetic via fallback for these rare inputs. */
        if(observed_repeat && g->multiple_repeats) {
            stats->wall_ms=now_ms(0)-wall;stats->cpu_ms=now_ms(1)-cpu;return -1;
        }
        if(g->geometry!=s->geometry) {
            for(int j=0;j<g->g.count;++j) g->g.shapes[j].measured=0;
            g->geometry=s->geometry;
        }
        if (g->generation!=s->generation) {
            for(int j=0;j<g->g.count;++j) g->g.scores[j].context_bonus=
                g->g.scores[j].enabled?bonus(s,g->refs[j]->word):0;
            g->generation=s->generation;
        }
        r->groups[i]=g->g;
    }
    stats->wall_ms=now_ms(0)-wall;stats->cpu_ms=now_ms(1)-cpu;
    return te_run(context_ptr,workspace,r,shape,out);
}
int td_word(TDStore *s,TDQuery query,int index,TDWord *word) {
    if (!s||!word) return 0;Group *g=resolve(s,query,NULL);
    if (!g||index<0||index>=g->g.count) return 0;
    Record *r=g->refs[index];*word=(TDWord){r->word,r->base,r->gesture};return 1;
}
int td_group(TDStore *s,TDQuery query,TEGroup *group) {
    if (!s||!group) return 0;Group *g=resolve(s,query,NULL);if (!g) return 0;
    *group=g->g;return 1;
}
