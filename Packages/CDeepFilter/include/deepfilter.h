// C interface of DeepFilterNet's libDF (Engines/deepfilter/DeepFilterNet/libDF/src/capi.rs).
#include <stddef.h>
typedef struct DFState DFState;
DFState *df_create(const char *model_path, float atten_lim_db, const char *log_level);
size_t df_get_frame_length(DFState *state);
void df_set_atten_lim(DFState *state, float lim_db);
void df_set_post_filter_beta(DFState *state, float beta);
float df_process_frame(DFState *state, float *input, float *output);
void df_free(DFState *state);
