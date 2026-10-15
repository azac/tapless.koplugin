typedef struct { int position; double count; } TCScanRepeat;
typedef struct {
    const char *word;
    int length, repeat_count, enabled;
    const TCScanRepeat *repeats;
    double frequency, context_bonus;
} TCScanEntry;
typedef struct {
    int start, end, near, points, has_next, edit_limit;
    double score_unit, repeat_bonus;
    const double *repeat_confidence;
} TCScanPolicy;
typedef struct { double spatial, ranked; int used_near; } TCScanResult;
int tc_scan_version(void);
int tc_scan_entry_size(void);
int tc_scan_policy_size(void);
int tc_scan_result_size(void);
int tc_edit_distance(const char *left, int left_length, const char *right, int right_length, int limit);
void tc_scan(TCGesture *gesture, const char *signature, int length,
    const TCScanEntry *entries, int count, const TCScanPolicy *policy, TCScanResult *results);
