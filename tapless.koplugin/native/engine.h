typedef struct { double x,y; int present,letter; } TEPoint;
typedef struct {
    TCScanEntry *scores;
    TSShapeEntry *shapes;
    int count;
} TEGroup;
typedef struct { int group,start,end,fallback; } TEScan;
typedef struct { int personal,normal; } TEShapePair;
typedef struct {
    int group,index,start,end,near,has_geometry;
    double spatial,ranked,geometry;
} TECandidate;
typedef struct {
    int enabled,attempted,accepted,reason,has_boundary,has_choice,stable,group,index;
    double start,endpoint,length,shape,spatial,margin,alt_margin;
} TEGate;
typedef struct {
    const char *signature;
    int length,limit,point_count,has_letter_points,has_observations,has_endpoint;
    const TEPoint *points,*letter_points;
    const double *weights,*turns,*repeats;
    const unsigned char *observed;
    TSShapeCenter centers[26];
    TEGroup *groups;
    int group_count;
    const TEScan *scans;
    int scan_count;
    const TEShapePair *pairs;
    int pair_count;
    TCScanPolicy scoring;
    double first_cost,start_cost,end_cost,near_cost,near_reach,min_turn,missing_cost;
    int near_limit,gate_enabled,gate_min_length,shape_trigger;
    double gate_boundary,gate_shape,gate_spatial,gate_margin;
    int samples;
    double geometry_weight,geometry_max,alignment_weight;
    double shape_budget_ms;
} TERequest;
typedef struct TEWorkspace TEWorkspace;
typedef struct {
    TECandidate hits[64];
    int count,fallback,scan_calls,scan_words,dynamic_calls,shape_calls;
    int shape_entries,shape_compared,shape_buckets,shape_exhausted;
    TEGate gate;
} TEOutput;
int te_abi_version(void);
int te_request_size(void);
int te_group_size(void);
int te_output_size(void);
int te_workspace_size(void);
int te_run(TCContext *context, TEWorkspace *workspace, TERequest *request,
    TSShapeState *shape, TEOutput *output);
