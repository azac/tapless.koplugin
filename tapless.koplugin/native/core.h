typedef struct TCContext TCContext;
typedef struct {
    int size, near_limit;
    double first_cost, start_cost, end_cost, near_cost;
    const unsigned char *letters, *lending, *adjacent, *near_present;
    const double *weights, *prefix, *px, *py, *cx, *cy, *cs;
    const unsigned char *point_valid, *center_valid;
    const int *next, *near_next;
    double *distances;
} TCGesture;
typedef struct { double score; int mismatch, omitted; } TCResult;
TCContext *tc_new(void);
void tc_free(TCContext *ctx);
void tc_init_distances(TCGesture *g);
int tc_can_finish(const TCGesture *g, const char *word, int length,
    int start, int end, int near, int reuse);
void tc_greedy(TCGesture *g, const char *word, int length, int start,
    int end, int near, int budget, int points, int has_next, int *positions, TCResult *result);
int tc_align(TCContext *ctx, TCGesture *g, const char *word, int length,
    int start, int end, int near, int has_omission, double omission,
    int points, int *positions, TCResult *result);

int tc_abi_version(void);
int tc_gesture_size(void);
int tc_result_size(void);
