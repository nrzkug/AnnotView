#include "MuPDFBridge.h"
#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <mupdf/fitz/json.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

void mupdf_bridge_free(char *ptr) {
    if (ptr) {
        free(ptr);
    }
}

static void set_error(char **out_error, const char *msg) {
    if (out_error) {
        *out_error = strdup(msg ? msg : "Unknown MuPDF error");
    }
}

static void escape_json_string(fz_context *ctx, fz_buffer *buf, const char *str) {
    if (!str) {
        fz_append_string(ctx, buf, "null");
        return;
    }
    fz_append_byte(ctx, buf, '"');
    const unsigned char *p = (const unsigned char *)str;
    while (*p) {
        switch (*p) {
            case '"': fz_append_string(ctx, buf, "\\\""); break;
            case '\\': fz_append_string(ctx, buf, "\\\\"); break;
            case '\b': fz_append_string(ctx, buf, "\\b"); break;
            case '\f': fz_append_string(ctx, buf, "\\f"); break;
            case '\n': fz_append_string(ctx, buf, "\\n"); break;
            case '\r': fz_append_string(ctx, buf, "\\r"); break;
            case '\t': fz_append_string(ctx, buf, "\\t"); break;
            default:
                if (*p < 32) {
                    fz_append_printf(ctx, buf, "\\u%04x", *p);
                } else {
                    fz_append_byte(ctx, buf, *p);
                }
                break;
        }
        p++;
    }
    fz_append_byte(ctx, buf, '"');
}

static void append_json_double(fz_context *ctx, fz_buffer *buf, double val) {
    if (isnan(val) || isinf(val)) {
        fz_append_string(ctx, buf, "0");
        return;
    }
    char s[64];
    snprintf(s, sizeof(s), "%.6f", val);
    char *dot = strchr(s, '.');
    if (dot) {
        char *end = s + strlen(s) - 1;
        while (end > dot && *end == '0') {
            *end-- = '\0';
        }
        if (end == dot) {
            *dot = '\0';
        }
    }
    if (strcmp(s, "-0") == 0) {
        fz_append_string(ctx, buf, "0");
    } else {
        fz_append_string(ctx, buf, s);
    }
}

static void append_json_double_array(fz_context *ctx, fz_buffer *buf, const double *vals, int count) {
    fz_append_byte(ctx, buf, '[');
    for (int i = 0; i < count; ++i) {
        if (i > 0) fz_append_byte(ctx, buf, ',');
        append_json_double(ctx, buf, vals[i]);
    }
    fz_append_byte(ctx, buf, ']');
}

static void append_iso_date(fz_context *ctx, fz_buffer *buf, int64_t epoch) {
    if (epoch <= 0) {
        fz_append_string(ctx, buf, "null");
        return;
    }
    time_t t = (time_t)epoch;
    struct tm tm_buf;
    gmtime_r(&t, &tm_buf);
    char date_str[32];
    strftime(date_str, sizeof(date_str), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
    fz_append_printf(ctx, buf, "\"%s\"", date_str);
}

static int64_t parse_iso_or_pdf_date(const char *str) {
    if (!str || !*str) return 0;
    struct tm tm_buf;
    memset(&tm_buf, 0, sizeof(tm_buf));
    if (sscanf(str, "%4d-%2d-%2dT%2d:%2d:%2d",
               &tm_buf.tm_year, &tm_buf.tm_mon, &tm_buf.tm_mday,
               &tm_buf.tm_hour, &tm_buf.tm_min, &tm_buf.tm_sec) == 6) {
        tm_buf.tm_year -= 1900;
        tm_buf.tm_mon -= 1;
        return (int64_t)timegm(&tm_buf);
    }
    return (int64_t)time(NULL);
}

static pdf_annot *find_annot_by_source_id(fz_context *ctx, pdf_document *doc, const char *source_id, pdf_page **out_page) {
    if (!source_id) return NULL;
    int target_num = 0;
    if (sscanf(source_id, "%d", &target_num) != 1 || target_num <= 0) {
        return NULL;
    }

    int page_count = pdf_count_pages(ctx, doc);
    for (int p = 0; p < page_count; ++p) {
        pdf_page *page = pdf_load_page(ctx, doc, p);
        for (pdf_annot *annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
            pdf_obj *obj = pdf_annot_obj(ctx, annot);
            if (pdf_to_num(ctx, obj) == target_num) {
                if (out_page) *out_page = page;
                else fz_drop_page(ctx, &page->super);
                return annot;
            }
        }
        fz_drop_page(ctx, &page->super);
    }
    return NULL;
}

bool mupdf_bridge_parse_annotations(const char *pdf_path, char **out_json, char **out_error) {
    if (!pdf_path || !out_json) {
        set_error(out_error, "Invalid parameters to mupdf_bridge_parse_annotations");
        return false;
    }
    *out_json = NULL;
    if (out_error) *out_error = NULL;

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) {
        set_error(out_error, "Failed to create MuPDF context");
        return false;
    }
    fz_register_document_handlers(ctx);

    bool success = false;
    pdf_document *doc = NULL;
    fz_buffer *buf = NULL;

    fz_try(ctx) {
        doc = pdf_open_document(ctx, pdf_path);
        int page_count = pdf_count_pages(ctx, doc);
        buf = fz_new_buffer(ctx, 4096);

        fz_append_string(ctx, buf, "{\"version\":1,\"pages\":[");

        for (int p = 0; p < page_count; ++p) {
            if (p > 0) fz_append_string(ctx, buf, ",");
            pdf_page *page = pdf_load_page(ctx, doc, p);
            fz_rect mediabox;
            fz_matrix ctm;
            pdf_page_transform(ctx, page, &mediabox, &ctm);

            fz_append_printf(ctx, buf, "{\"pageIndex\":%d,\"pageTransform\":", p);
            double ctm_vals[6] = { ctm.a, ctm.b, ctm.c, ctm.d, ctm.e, ctm.f };
            append_json_double_array(ctx, buf, ctm_vals, 6);
            fz_append_string(ctx, buf, ",\"pageBounds\":");
            double mb_vals[4] = { mediabox.x0, mediabox.y0, mediabox.x1, mediabox.y1 };
            append_json_double_array(ctx, buf, mb_vals, 4);
            fz_append_string(ctx, buf, ",\"annotations\":[");

            int annot_idx = 0;
            for (pdf_annot *annot = pdf_first_annot(ctx, page); annot; annot = pdf_next_annot(ctx, annot)) {
                if (annot_idx > 0) fz_append_string(ctx, buf, ",");
                annot_idx++;

                pdf_obj *obj = pdf_annot_obj(ctx, annot);
                enum pdf_annot_type type = pdf_annot_type(ctx, annot);
                const char *type_name = pdf_string_from_annot_type(ctx, type);
                fz_rect bounds = pdf_bound_annot(ctx, annot);

                if (type == PDF_ANNOT_CARET || type == PDF_ANNOT_TEXT) {
                    pdf_obj *rect_obj = pdf_dict_get(ctx, obj, PDF_NAME(Rect));
                    if (pdf_is_array(ctx, rect_obj) && pdf_array_len(ctx, rect_obj) == 4) {
                        float r0 = pdf_to_real(ctx, pdf_array_get(ctx, rect_obj, 0));
                        float r1 = pdf_to_real(ctx, pdf_array_get(ctx, rect_obj, 1));
                        float r2 = pdf_to_real(ctx, pdf_array_get(ctx, rect_obj, 2));
                        float r3 = pdf_to_real(ctx, pdf_array_get(ctx, rect_obj, 3));
                        fz_matrix inv = fz_invert_matrix(ctm);
                        fz_point p0 = fz_transform_point_xy(r0, r1, inv);
                        fz_point p1 = fz_transform_point_xy(r2, r3, inv);
                        bounds.x0 = fz_min(p0.x, p1.x);
                        bounds.y0 = fz_min(p0.y, p1.y);
                        bounds.x1 = fz_max(p0.x, p1.x);
                        bounds.y1 = fz_max(p0.y, p1.y);
                    }
                }

                int obj_num = pdf_to_num(ctx, obj);
                pdf_obj *parent = pdf_dict_get(ctx, obj, PDF_NAME(IRT));
                int parent_num = pdf_to_num(ctx, parent);

                fz_append_string(ctx, buf, "{\"sourceID\":");
                if (obj_num > 0) fz_append_printf(ctx, buf, "\"%d 0 R\",", obj_num);
                else fz_append_string(ctx, buf, "null,");

                fz_append_string(ctx, buf, "\"inReplyToSourceID\":");
                if (parent_num > 0) fz_append_printf(ctx, buf, "\"%d 0 R\",", parent_num);
                else fz_append_string(ctx, buf, "null,");

                fz_append_printf(ctx, buf, "\"type\":\"%s\",", type_name ? type_name : "Unknown");
                fz_append_string(ctx, buf, "\"bounds\":");
                double b_vals[4] = { bounds.x0, bounds.y0, bounds.x1, bounds.y1 };
                append_json_double_array(ctx, buf, b_vals, 4);
                fz_append_string(ctx, buf, ",");

                // QuadPoints
                fz_append_string(ctx, buf, "\"quadPoints\":[");
                if (pdf_annot_has_quad_points(ctx, annot)) {
                    int qcount = pdf_annot_quad_point_count(ctx, annot);
                    for (int q = 0; q < qcount; ++q) {
                        if (q > 0) fz_append_string(ctx, buf, ",");
                        fz_quad quad = pdf_annot_quad_point(ctx, annot, q);
                        double q_vals[8] = {
                            quad.ul.x, quad.ul.y, quad.ur.x, quad.ur.y,
                            quad.ll.x, quad.ll.y, quad.lr.x, quad.lr.y
                        };
                        append_json_double_array(ctx, buf, q_vals, 8);
                    }
                }
                fz_append_string(ctx, buf, "],");

                // Contents, Author, Subject
                fz_append_string(ctx, buf, "\"contents\":");
                escape_json_string(ctx, buf, pdf_annot_contents(ctx, annot));
                fz_append_string(ctx, buf, ",\"author\":");
                escape_json_string(ctx, buf, pdf_annot_author(ctx, annot));
                fz_append_string(ctx, buf, ",\"subject\":");
                pdf_obj *subj_obj = pdf_dict_get(ctx, obj, PDF_NAME(Subj));
                escape_json_string(ctx, buf, pdf_to_text_string(ctx, subj_obj));

                // Creation & Mod Date
                fz_append_string(ctx, buf, ",\"creationDate\":");
                append_iso_date(ctx, buf, pdf_annot_creation_date(ctx, annot));
                fz_append_string(ctx, buf, ",\"modificationDate\":");
                append_iso_date(ctx, buf, pdf_annot_modification_date(ctx, annot));

                // Color & Opacity
                float color[4] = {0};
                int ncolor = 0;
                pdf_annot_color(ctx, annot, &ncolor, color);
                fz_append_string(ctx, buf, ",\"color\":[");
                for (int c = 0; c < ncolor; ++c) {
                    if (c > 0) fz_append_string(ctx, buf, ",");
                    append_json_double(ctx, buf, color[c]);
                }
                fz_append_string(ctx, buf, "],\"opacity\":");
                append_json_double(ctx, buf, pdf_annot_opacity(ctx, annot));
                fz_append_string(ctx, buf, ",");

                // StateModel & State
                pdf_obj *sm_obj = pdf_dict_gets(ctx, obj, "StateModel");
                fz_append_string(ctx, buf, "\"stateModel\":");
                if (sm_obj) escape_json_string(ctx, buf, pdf_to_name(ctx, sm_obj));
                else fz_append_string(ctx, buf, "null");

                pdf_obj *st_obj = pdf_dict_gets(ctx, obj, "State");
                fz_append_string(ctx, buf, ",\"state\":");
                if (st_obj) escape_json_string(ctx, buf, pdf_to_name(ctx, st_obj));
                else fz_append_string(ctx, buf, "null");

                fz_append_string(ctx, buf, "}");
            }
            fz_append_string(ctx, buf, "]}");
            fz_drop_page(ctx, &page->super);
        }
        fz_append_string(ctx, buf, "]}");

        unsigned char *data = NULL;
        size_t len = fz_buffer_storage(ctx, buf, &data);
        *out_json = (char *)malloc(len + 1);
        if (*out_json) {
            memcpy(*out_json, data, len);
            (*out_json)[len] = '\0';
            success = true;
        } else {
            set_error(out_error, "Out of memory allocating JSON string");
        }
    }
    fz_catch(ctx) {
        set_error(out_error, fz_caught_message(ctx));
        success = false;
    }

    if (buf) fz_drop_buffer(ctx, buf);
    if (doc) pdf_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return success;
}

static fz_point transform_point(fz_point pt, fz_matrix mat) {
    return (fz_point){
        pt.x * mat.a + pt.y * mat.c + mat.e,
        pt.x * mat.b + pt.y * mat.d + mat.f
    };
}

static fz_quad to_mupdf_quad(double *vals, fz_matrix inv) {
    fz_point pts[4];
    for (int i = 0; i < 4; ++i) {
        pts[i] = transform_point((fz_point){vals[i * 2], vals[i * 2 + 1]}, inv);
    }
    float min_x = fz_min(fz_min(pts[0].x, pts[1].x), fz_min(pts[2].x, pts[3].x));
    float max_x = fz_max(fz_max(pts[0].x, pts[1].x), fz_max(pts[2].x, pts[3].x));
    float min_y = fz_min(fz_min(pts[0].y, pts[1].y), fz_min(pts[2].y, pts[3].y));
    float max_y = fz_max(fz_max(pts[0].y, pts[1].y), fz_max(pts[2].y, pts[3].y));
    return (fz_quad){
        .ul = {min_x, min_y},
        .ur = {max_x, min_y},
        .ll = {min_x, max_y},
        .lr = {max_x, max_y}
    };
}

static void set_common_fields(fz_context *ctx, pdf_annot *annot, const char *name,
                              const char *author, const char *contents, const char *timestamp,
                              float *color, int ncolor, float opacity) {
    int64_t t = parse_iso_or_pdf_date(timestamp);
    int type = pdf_annot_type(ctx, annot);
    pdf_set_annot_flags(ctx, annot, type == PDF_ANNOT_TEXT ? 28 : 4);
    if (name) {
        pdf_obj *obj = pdf_annot_obj(ctx, annot);
        pdf_dict_put_string(ctx, obj, PDF_NAME(NM), name, strlen(name));
    }
    if (author) pdf_set_annot_author(ctx, annot, author);
    if (contents) pdf_set_annot_contents(ctx, annot, contents);
    if (ncolor > 0 && color) pdf_set_annot_color(ctx, annot, ncolor, color);
    pdf_set_annot_opacity(ctx, annot, opacity);
    if (t > 0) {
        pdf_set_annot_creation_date(ctx, annot, t);
        pdf_set_annot_modification_date(ctx, annot, t);
    }
}

static void finish_appearance(fz_context *ctx, pdf_annot *annot, float opacity) {
    pdf_update_annot(ctx, annot);
    pdf_obj *obj = pdf_annot_obj(ctx, annot);
    pdf_dict_put_real(ctx, obj, PDF_NAME(CA), opacity);
}

bool mupdf_bridge_write_annotations(const char *input_path, const char *output_path, const char *operations_json, char **out_error) {
    if (!input_path || !output_path || !operations_json) {
        set_error(out_error, "Invalid parameters to mupdf_bridge_write_annotations");
        return false;
    }
    if (out_error) *out_error = NULL;

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) {
        set_error(out_error, "Failed to create MuPDF context");
        return false;
    }
    fz_register_document_handlers(ctx);

    bool success = false;
    pdf_document *doc = NULL;
    fz_pool *pool = fz_new_pool(ctx);

    fz_try(ctx) {
        doc = pdf_open_document(ctx, input_path);
        fz_json *root = fz_parse_json(ctx, pool, operations_json);
        if (!root) fz_throw(ctx, FZ_ERROR_GENERIC, "Failed to parse operations JSON");

        fz_json *ops_arr = fz_json_object_get(ctx, root, "operations");
        if (!ops_arr || !fz_json_is_array(ctx, ops_arr)) {
            fz_throw(ctx, FZ_ERROR_GENERIC, "Missing operations array in payload");
        }

        int op_count = fz_json_array_length(ctx, ops_arr);
        for (int i = 0; i < op_count; ++i) {
            fz_json *op = fz_json_array_get(ctx, ops_arr, i);
            const char *op_name = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "operation"));
            if (!op_name) continue;

            if (strcmp(op_name, "createMarkup") == 0) {
                const char *subtype = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "subtype"));
                const char *name = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "name"));
                const char *author = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "author"));
                const char *contents = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "contents"));
                const char *timestamp = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "timestamp"));
                float opacity = (float)fz_json_to_number(ctx, fz_json_object_get(ctx, op, "opacity"));
                if (opacity <= 0) opacity = 1.0f;

                float color[3] = {1.0f, 0.819608f, 0.0f};
                fz_json *c_arr = fz_json_object_get(ctx, op, "color");
                if (c_arr && fz_json_is_array(ctx, c_arr) && fz_json_array_length(ctx, c_arr) == 3) {
                    color[0] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 0));
                    color[1] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 1));
                    color[2] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 2));
                }

                enum pdf_annot_type atype = pdf_annot_type_from_string(ctx, subtype);
                fz_json *pages_arr = fz_json_object_get(ctx, op, "pages");
                int npages = pages_arr ? fz_json_array_length(ctx, pages_arr) : 0;

                for (int pi = 0; pi < npages; ++pi) {
                    fz_json *page_item = fz_json_array_get(ctx, pages_arr, pi);
                    int pindex = (int)fz_json_to_number(ctx, fz_json_object_get(ctx, page_item, "pageIndex"));
                    if (pindex < 0 || pindex >= pdf_count_pages(ctx, doc)) continue;

                    pdf_page *page = pdf_load_page(ctx, doc, pindex);
                    fz_rect mbox; fz_matrix ctm;
                    pdf_page_transform(ctx, page, &mbox, &ctm);
                    fz_matrix inv = fz_invert_matrix(ctm);

                    fz_json *quads_arr = fz_json_object_get(ctx, page_item, "quads");
                    int nquads = quads_arr ? fz_json_array_length(ctx, quads_arr) : 0;
                    if (nquads == 0) {
                        fz_drop_page(ctx, &page->super);
                        continue;
                    }

                    fz_quad *mupdf_quads = (fz_quad *)malloc(sizeof(fz_quad) * nquads);
                    for (int qi = 0; qi < nquads; ++qi) {
                        fz_json *q_arr = fz_json_array_get(ctx, quads_arr, qi);
                        double vals[8];
                        for (int k = 0; k < 8; ++k) {
                            vals[k] = fz_json_to_number(ctx, fz_json_array_get(ctx, q_arr, k));
                        }
                        mupdf_quads[qi] = to_mupdf_quad(vals, inv);
                    }

                    pdf_annot *annot = pdf_create_annot(ctx, page, atype);
                    pdf_set_annot_quad_points(ctx, annot, nquads, mupdf_quads);
                    free(mupdf_quads);

                    if (subtype && strcmp(subtype, "StrikeOut") == 0) {
                        pdf_dict_put_name(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(Subj), "Strikethrough");
                    } else if (subtype) {
                        pdf_dict_put_name(ctx, pdf_annot_obj(ctx, annot), PDF_NAME(Subj), subtype);
                    }

                    char annot_name[256];
                    if (npages > 1) snprintf(annot_name, sizeof(annot_name), "%s-%d", name ? name : "Markup", pindex);
                    else snprintf(annot_name, sizeof(annot_name), "%s", name ? name : "Markup");

                    set_common_fields(ctx, annot, annot_name, author, contents, timestamp, color, 3, opacity);
                    finish_appearance(ctx, annot, opacity);
                    fz_drop_page(ctx, &page->super);
                }
            } else if (strcmp(op_name, "createNote") == 0) {
                fz_json *loc = fz_json_object_get(ctx, op, "location");
                int pindex = (int)fz_json_to_number(ctx, fz_json_object_get(ctx, loc, "pageIndex"));
                fz_json *pt_arr = fz_json_object_get(ctx, loc, "point");
                double pt_x = fz_json_to_number(ctx, fz_json_array_get(ctx, pt_arr, 0));
                double pt_y = fz_json_to_number(ctx, fz_json_array_get(ctx, pt_arr, 1));

                pdf_page *page = pdf_load_page(ctx, doc, pindex);
                fz_rect mbox; fz_matrix ctm;
                pdf_page_transform(ctx, page, &mbox, &ctm);
                fz_matrix inv = fz_invert_matrix(ctm);
                fz_point note_pt = transform_point((fz_point){pt_x, pt_y}, inv);

                pdf_annot *note = pdf_create_annot(ctx, page, PDF_ANNOT_TEXT);
                fz_rect note_rect = {note_pt.x - 10, note_pt.y - 10, note_pt.x + 10, note_pt.y + 10};
                pdf_set_annot_rect(ctx, note, note_rect);
                pdf_dict_put_name(ctx, pdf_annot_obj(ctx, note), PDF_NAME(Name), "Comment");
                pdf_dict_put_name(ctx, pdf_annot_obj(ctx, note), PDF_NAME(Subj), "Sticky Note");
                pdf_dict_put_bool(ctx, pdf_annot_obj(ctx, note), PDF_NAME(Open), 0);

                const char *name = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "name"));
                const char *author = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "author"));
                const char *contents = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "contents"));
                const char *timestamp = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "timestamp"));
                float opacity = (float)fz_json_to_number(ctx, fz_json_object_get(ctx, op, "opacity"));
                if (opacity <= 0) opacity = 1.0f;

                float color[3] = {1.0f, 0.819608f, 0.0f};
                fz_json *c_arr = fz_json_object_get(ctx, op, "color");
                if (c_arr && fz_json_is_array(ctx, c_arr) && fz_json_array_length(ctx, c_arr) == 3) {
                    color[0] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 0));
                    color[1] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 1));
                    color[2] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 2));
                }

                set_common_fields(ctx, note, name, author, contents, timestamp, color, 3, opacity);
                finish_appearance(ctx, note, opacity);
                fz_drop_page(ctx, &page->super);
            } else if (strcmp(op_name, "createCaret") == 0) {
                fz_json *loc = fz_json_object_get(ctx, op, "location");
                int pindex = (int)fz_json_to_number(ctx, fz_json_object_get(ctx, loc, "pageIndex"));
                fz_json *pt_arr = fz_json_object_get(ctx, loc, "point");
                double pt_x = fz_json_to_number(ctx, fz_json_array_get(ctx, pt_arr, 0));
                double pt_y = fz_json_to_number(ctx, fz_json_array_get(ctx, pt_arr, 1));

                pdf_page *page = pdf_load_page(ctx, doc, pindex);
                pdf_annot *caret = pdf_create_annot(ctx, page, PDF_ANNOT_CARET);
                pdf_dict_put_name(ctx, pdf_annot_obj(ctx, caret), PDF_NAME(Subj), "InsertedText");

                const char *name = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "name"));
                const char *author = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "author"));
                const char *contents = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "contents"));
                const char *timestamp = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "timestamp"));
                float opacity = (float)fz_json_to_number(ctx, fz_json_object_get(ctx, op, "opacity"));
                if (opacity <= 0) opacity = 1.0f;

                float color[3] = {0.972549f, 0.392151f, 0.392151f};
                fz_json *c_arr = fz_json_object_get(ctx, op, "color");
                if (c_arr && fz_json_is_array(ctx, c_arr) && fz_json_array_length(ctx, c_arr) == 3) {
                    color[0] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 0));
                    color[1] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 1));
                    color[2] = (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 2));
                }

                set_common_fields(ctx, caret, name, author, contents, timestamp, color, 3, opacity);
                finish_appearance(ctx, caret, opacity);

                // Set exact Acrobat leaf appearance
                pdf_obj *caret_obj = pdf_annot_obj(ctx, caret);
                fz_rect caret_rect = {
                    (float)(pt_x - 4.4235), (float)(pt_y - 3.6045),
                    (float)(pt_x + 4.4235), (float)(pt_y + 3.6045)
                };
                pdf_set_annot_rect(ctx, caret, caret_rect);

                char glyph[256];
                snprintf(glyph, sizeof(glyph),
                    "%g %g %g RG\n0.6007 w\n%g %g %g rg\n0 0 m\n3.8227 0 3.8227 3.0035 3.8227 6.007 c\n3.8227 3.0035 3.8227 0 7.6454 0 c\nh\nf\nS\n",
                    color[0], color[1], color[2], color[0], color[1], color[2]);

                fz_buffer *stream_buf = fz_new_buffer_from_copied_data(ctx, (unsigned char *)glyph, strlen(glyph));
                pdf_obj *ap_stream = pdf_add_stream(ctx, doc, stream_buf, NULL, 0);
                fz_drop_buffer(ctx, stream_buf);

                pdf_dict_put_name(ctx, ap_stream, PDF_NAME(Type), "XObject");
                pdf_dict_put_name(ctx, ap_stream, PDF_NAME(Subtype), "Form");
                pdf_dict_put_int(ctx, ap_stream, PDF_NAME(FormType), 1);
                pdf_dict_put_rect(ctx, ap_stream, PDF_NAME(BBox), (fz_rect){-0.30035f, -0.30035f, 7.94575f, 6.30735f});

                pdf_obj *ap_dict = pdf_new_dict(ctx, doc, 1);
                pdf_dict_put(ctx, ap_dict, PDF_NAME(N), ap_stream);
                pdf_dict_put_drop(ctx, caret_obj, PDF_NAME(AP), ap_dict);
                pdf_drop_obj(ctx, ap_stream);

                fz_drop_page(ctx, &page->super);
            } else if (strcmp(op_name, "move") == 0) {
                const char *source_id = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "sourceID"));
                pdf_page *page = NULL;
                pdf_annot *annot = find_annot_by_source_id(ctx, doc, source_id, &page);
                if (!annot || !page) {
                    char err_buf[128];
                    snprintf(err_buf, sizeof(err_buf), "annotation object %s was not found", source_id ? source_id : "null");
                    fz_throw(ctx, FZ_ERROR_GENERIC, "%s", err_buf);
                }
                fz_json *r_arr = fz_json_object_get(ctx, op, "rect");
                if (r_arr && fz_json_array_length(ctx, r_arr) == 4) {
                    pdf_obj *obj = pdf_annot_obj(ctx, annot);
                    pdf_obj *rect_arr = pdf_new_array(ctx, doc, 4);
                    for (int k = 0; k < 4; ++k) {
                        pdf_array_push_real(ctx, rect_arr, (float)fz_json_to_number(ctx, fz_json_array_get(ctx, r_arr, k)));
                    }
                    pdf_dict_puts_drop(ctx, obj, "Rect", rect_arr);

                    const char *ts = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "timestamp"));
                    int64_t t = parse_iso_or_pdf_date(ts);
                    if (t > 0) pdf_set_annot_modification_date(ctx, annot, t);

                    if (pdf_annot_type(ctx, annot) == PDF_ANNOT_CARET) {
                        pdf_dict_dels(ctx, obj, "AP");
                        pdf_dict_dels(ctx, obj, "CA");
                    }
                }
                fz_drop_page(ctx, &page->super);
            } else if (strcmp(op_name, "update") == 0) {
                const char *source_id = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "sourceID"));
                pdf_page *page = NULL;
                pdf_annot *annot = find_annot_by_source_id(ctx, doc, source_id, &page);
                if (!annot || !page) {
                    char err_buf[128];
                    snprintf(err_buf, sizeof(err_buf), "annotation object %s was not found", source_id ? source_id : "null");
                    fz_throw(ctx, FZ_ERROR_GENERIC, "%s", err_buf);
                }
                pdf_obj *obj = pdf_annot_obj(ctx, annot);
                pdf_obj *preserved_rect = NULL;
                if (pdf_annot_type(ctx, annot) == PDF_ANNOT_CARET) {
                    pdf_obj *r = pdf_dict_get(ctx, obj, PDF_NAME(Rect));
                    if (r) preserved_rect = pdf_keep_obj(ctx, r);
                }

                const char *contents = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "contents"));
                if (contents) pdf_set_annot_contents(ctx, annot, contents);

                const char *author = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "author"));
                if (author) pdf_set_annot_author(ctx, annot, author);

                const char *timestamp = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "timestamp"));
                if (timestamp) {
                    int64_t t = parse_iso_or_pdf_date(timestamp);
                    if (t > 0) pdf_set_annot_modification_date(ctx, annot, t);
                }

                float opacity = (float)fz_json_to_number(ctx, fz_json_object_get(ctx, op, "opacity"));
                if (opacity > 0) pdf_set_annot_opacity(ctx, annot, opacity);

                fz_json *c_arr = fz_json_object_get(ctx, op, "color");
                if (c_arr && fz_json_array_length(ctx, c_arr) == 3) {
                    float color[3] = {
                        (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 0)),
                        (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 1)),
                        (float)fz_json_to_number(ctx, fz_json_array_get(ctx, c_arr, 2))
                    };
                    pdf_set_annot_color(ctx, annot, 3, color);
                }
                finish_appearance(ctx, annot, opacity > 0 ? opacity : 1.0f);

                if (preserved_rect) {
                    pdf_dict_puts_drop(ctx, obj, "Rect", preserved_rect);
                    pdf_dict_dels(ctx, obj, "AP");
                    pdf_dict_dels(ctx, obj, "CA");
                }

                fz_drop_page(ctx, &page->super);
            } else if (strcmp(op_name, "delete") == 0) {
                const char *source_id = fz_json_to_string(ctx, fz_json_object_get(ctx, op, "sourceID"));
                pdf_page *page = NULL;
                pdf_annot *annot = find_annot_by_source_id(ctx, doc, source_id, &page);
                if (!annot || !page) {
                    char err_buf[128];
                    snprintf(err_buf, sizeof(err_buf), "annotation object %s was not found", source_id ? source_id : "null");
                    fz_throw(ctx, FZ_ERROR_GENERIC, "%s", err_buf);
                }
                pdf_delete_annot(ctx, page, annot);
                fz_drop_page(ctx, &page->super);
            }
        }

        pdf_write_options opts = pdf_default_write_options;
        opts.do_incremental = 0;
        pdf_save_document(ctx, doc, output_path, &opts);
        success = true;
    }
    fz_catch(ctx) {
        set_error(out_error, fz_caught_message(ctx));
        success = false;
    }

    fz_drop_pool(ctx, pool);
    if (doc) pdf_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return success;
}

bool mupdf_bridge_update_statuses(const char *input_path, const char *output_path, const char *statuses_json, char **out_error) {
    if (!input_path || !output_path || !statuses_json) {
        set_error(out_error, "Invalid parameters to mupdf_bridge_update_statuses");
        return false;
    }
    if (out_error) *out_error = NULL;

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) {
        set_error(out_error, "Failed to create MuPDF context");
        return false;
    }
    fz_register_document_handlers(ctx);

    bool success = false;
    pdf_document *doc = NULL;
    fz_pool *pool = fz_new_pool(ctx);

    fz_try(ctx) {
        doc = pdf_open_document(ctx, input_path);
        fz_json *root = fz_parse_json(ctx, pool, statuses_json);
        if (!root) fz_throw(ctx, FZ_ERROR_GENERIC, "Failed to parse statuses JSON");

        fz_json *updates_arr = fz_json_object_get(ctx, root, "updates");
        if (!updates_arr) updates_arr = fz_json_object_get(ctx, root, "mutations");
        if (!updates_arr || !fz_json_is_array(ctx, updates_arr)) {
            fz_throw(ctx, FZ_ERROR_GENERIC, "Missing updates array in payload");
        }

        int count = fz_json_array_length(ctx, updates_arr);
        for (int i = 0; i < count; ++i) {
            fz_json *item = fz_json_array_get(ctx, updates_arr, i);
            const char *source_id = fz_json_to_string(ctx, fz_json_object_get(ctx, item, "sourceID"));
            const char *state_model = fz_json_to_string(ctx, fz_json_object_get(ctx, item, "stateModel"));
            const char *state = fz_json_to_string(ctx, fz_json_object_get(ctx, item, "state"));
            if (!state) state = fz_json_to_string(ctx, fz_json_object_get(ctx, item, "status"));
            if (!state_model) state_model = "Review";
            if (!source_id || !state) continue;

            pdf_page *page = NULL;
            pdf_annot *target_annot = find_annot_by_source_id(ctx, doc, source_id, &page);
            if (!target_annot || !page) {
                char err_buf[128];
                snprintf(err_buf, sizeof(err_buf), "annotation object %s was not found", source_id);
                fz_throw(ctx, FZ_ERROR_GENERIC, "%s", err_buf);
            }

            pdf_obj *target_obj = pdf_annot_obj(ctx, target_annot);
            pdf_dict_puts_drop(ctx, target_obj, "StateModel", pdf_new_name(ctx, state_model));
            pdf_dict_puts_drop(ctx, target_obj, "State", pdf_new_name(ctx, state));
            fz_drop_page(ctx, &page->super);
        }

        pdf_write_options opts = pdf_default_write_options;
        opts.do_incremental = 0;
        pdf_save_document(ctx, doc, output_path, &opts);
        success = true;
    }
    fz_catch(ctx) {
        set_error(out_error, fz_caught_message(ctx));
        success = false;
    }

    fz_drop_pool(ctx, pool);
    if (doc) pdf_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return success;
}

bool mupdf_bridge_strip_annotations(const char *input_path, const char *output_path, char **out_error) {
    if (!input_path || !output_path) {
        set_error(out_error, "Invalid parameters to mupdf_bridge_strip_annotations");
        return false;
    }
    if (out_error) *out_error = NULL;

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_UNLIMITED);
    if (!ctx) {
        set_error(out_error, "Failed to create MuPDF context");
        return false;
    }
    fz_register_document_handlers(ctx);

    bool success = false;
    pdf_document *doc = NULL;

    fz_try(ctx) {
        doc = pdf_open_document(ctx, input_path);
        int page_count = pdf_count_pages(ctx, doc);
        for (int p = 0; p < page_count; ++p) {
            pdf_page *page = pdf_load_page(ctx, doc, p);
            pdf_annot *annot = pdf_first_annot(ctx, page);
            while (annot) {
                pdf_annot *next = pdf_next_annot(ctx, annot);
                pdf_delete_annot(ctx, page, annot);
                annot = next;
            }
            fz_drop_page(ctx, &page->super);
        }

        pdf_write_options opts = pdf_default_write_options;
        opts.do_incremental = 0;
        pdf_save_document(ctx, doc, output_path, &opts);
        success = true;
    }
    fz_catch(ctx) {
        set_error(out_error, fz_caught_message(ctx));
        success = false;
    }

    if (doc) pdf_drop_document(ctx, doc);
    fz_drop_context(ctx);
    return success;
}
