typedef struct { double x, y, size; int present; } TSShapeCenter;
typedef struct {
    const char *word, *signature;
    int word_length, signature_length, minimum_length, enabled;
    double frequency, length, scale;
    int measured;
} TSShapeEntry;
typedef struct { const char *key; int length; unsigned int hash, generation; } TSWordSlot;
typedef struct {
    const char *key; int length; unsigned int hash, generation;
    double shape, bound; int has_shape, has_bound;
} TSSignatureSlot;
typedef struct { int group, index; double shape, rank; } TSShapeHit;
typedef struct {
    TSShapeCenter centers[26];
    double x[64], y[64], length;
    int samples, min_letters, max_entries, max_comparisons, keep, capacity;
    double min_ratio, max_ratio, max_shape, shape_weight, max_score;
    TSWordSlot *words;
    TSSignatureSlot *signatures;
    TSShapeHit *hits;
    int entries, compared, exhausted, count, overflow;
    unsigned int generation;
} TSShapeState;
int ts_abi_version(void);
int ts_state_size(void);
int ts_entry_size(void);
int ts_word_slot_size(void);
int ts_signature_slot_size(void);
int ts_hit_size(void);
int ts_shape_scan(TSShapeState *state, TSShapeEntry *entries, int count, int group, int offset);
