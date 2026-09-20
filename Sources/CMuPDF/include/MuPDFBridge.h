#ifndef MUPDF_BRIDGE_H
#define MUPDF_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

bool mupdf_bridge_parse_annotations(const char *pdf_path, char **out_json, char **out_error);
bool mupdf_bridge_write_annotations(const char *input_path, const char *output_path, const char *operations_json, char **out_error);
bool mupdf_bridge_update_statuses(const char *input_path, const char *output_path, const char *statuses_json, char **out_error);
bool mupdf_bridge_strip_annotations(const char *input_path, const char *output_path, char **out_error);
void mupdf_bridge_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* MUPDF_BRIDGE_H */
