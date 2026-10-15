typedef struct TDStore TDStore;
typedef struct { int first,last,length,kind; } TDQuery;
typedef struct { const char *word; double bonus; } TDBonus;
typedef struct { const char *word,*signature,*gesture_signature; } TDWord;
typedef struct { double wall_ms,cpu_ms; int loaded,entries; } TDStats;
int td_abi_version(void);
TDStore *td_open(const char *data,const char *index,const char *popular_data,const char *popular_index,
    const char *dictionary,const char *language);
void td_free(TDStore *store);
int td_run(TDStore *store, const TDQuery *queries, const TDBonus *bonuses,int bonus_count,
    TCContext *context, TEWorkspace *workspace, TERequest *request,TSShapeState *shape,TEOutput *output,TDStats *stats);
int td_word(TDStore *store,TDQuery query,int index,TDWord *word);
int td_group(TDStore *store,TDQuery query,TEGroup *group);
