#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define TENSOR_MAGIC   ((UV)0x54454e53U) /* "TENS" */
#define TENSOR_VERSION ((UV)1)

typedef struct {
    UV magic;
    UV version;
    UV rank;
    UV size;
    /* Followed by rank UV shape values, rank UV stride values, and size
     * NV data values, then a zero UV sentinel.  The whole representation is
     * owned by one PV. */
} tensor_header;

static Size_t
tensor_align_offset(Size_t offset)
{
    const Size_t alignment = MEM_ALIGNBYTES;
    return (offset + alignment - 1) / alignment * alignment;
}

static Size_t
tensor_data_offset(UV rank)
{
    return tensor_align_offset(sizeof(tensor_header)
                               + rank * sizeof(UV) * 2);
}

static bool
tensor_blob_size(UV rank, UV size, Size_t *result)
{
    Size_t metadata;
    Size_t data_offset;
    Size_t data_bytes;
    Size_t tail_offset;

    if (rank > (UV)Size_t_MAX
        || (Size_t)rank > (Size_t_MAX - sizeof(tensor_header))
                            / (sizeof(UV) * 2)
        || size > (UV)(Size_t_MAX / sizeof(NV)))
        return FALSE;

    metadata = sizeof(tensor_header) + (Size_t)rank * sizeof(UV) * 2;
    if (metadata > Size_t_MAX - MEM_ALIGNBYTES + 1)
        return FALSE;
    data_offset = tensor_align_offset(metadata);
    data_bytes = (Size_t)size * sizeof(NV);
    if (data_offset > Size_t_MAX - data_bytes)
        return FALSE;
    metadata = data_offset + data_bytes;
    if (metadata > Size_t_MAX - MEM_ALIGNBYTES + 1)
        return FALSE;
    tail_offset = tensor_align_offset(metadata);
    if (tail_offset > Size_t_MAX - sizeof(UV))
        return FALSE;

    *result = tail_offset + sizeof(UV);
    return TRUE;
}

static tensor_header *
tensor_from_object(pTHX_ SV *object)
{
    SV *payload;

    if (!SvROK(object) || !SvPOK(SvRV(object)))
        croak("Tensor::XS object expected");

    payload = SvRV(object);
    if (SvCUR(payload) < sizeof(tensor_header))
        croak("invalid Tensor::XS object");

    {
        tensor_header *tensor = (tensor_header *)SvPV_nolen(payload);
        Size_t expected;
        if (tensor->magic != TENSOR_MAGIC || tensor->version != TENSOR_VERSION
            || !tensor_blob_size(tensor->rank, tensor->size, &expected)
            || SvCUR(payload) < expected)
            croak("invalid Tensor::XS object");
        return tensor;
    }
}

static UV *
tensor_shape(tensor_header *tensor)
{
    return (UV *)(tensor + 1);
}

static UV *
tensor_strides(tensor_header *tensor)
{
    return tensor_shape(tensor) + tensor->rank;
}

static NV *
tensor_data(tensor_header *tensor)
{
    return (NV *)((char *)tensor + tensor_data_offset(tensor->rank));
}

static UV
tensor_coordinate_index(pTHX_ tensor_header *tensor, SV **coordinates,
                        I32 count)
{
    UV index = 0;
    I32 i;

    if ((UV)count != tensor->rank)
        croak("coordinate count does not match tensor rank");

    for (i = 0; i < count; i++) {
        IV coordinate = SvIV(coordinates[i]);
        if (coordinate < 0 || (UV)coordinate >= tensor_shape(tensor)[i])
            croak("tensor coordinate out of bounds");
        index += (UV)coordinate * tensor_strides(tensor)[i];
    }

    return index;
}

static void
tensor_copy_array(pTHX_ AV *source, tensor_header *tensor, UV depth,
                  UV *position, NV *output)
{
    const UV count = av_count(source);
    UV i;

    if (depth == 0 && count == tensor->size
        && (!count || !SvROK(*av_fetch(source, 0, 0)))) {
        for (i = 0; i < count; i++) {
            SV *value = *av_fetch(source, i, 0);
            if (SvROK(value))
                croak("flat tensor data cannot contain nested arrays");
            output[(*position)++] = SvNV(value);
        }
        return;
    }

    if (depth >= tensor->rank || count != tensor_shape(tensor)[depth])
        croak("nested tensor data does not match tensor shape");

    for (i = 0; i < count; i++) {
        SV *value = *av_fetch(source, i, 0);
        if (depth + 1 == tensor->rank) {
            if (SvROK(value))
                croak("nested tensor data has too many dimensions");
            output[(*position)++] = SvNV(value);
        }
        else {
            if (!SvROK(value) || SvTYPE(SvRV(value)) != SVt_PVAV)
                croak("nested tensor data has too few dimensions");
            tensor_copy_array(aTHX_ (AV *)SvRV(value), tensor, depth + 1,
                              position, output);
        }
    }
}

MODULE = Tensor::XS  PACKAGE = Tensor::XS

PROTOTYPES: DISABLE

SV *
new(class, shape, data)
    const char *class
    SV *shape
    SV *data
  PREINIT:
    AV *shape_av;
    AV *data_av = NULL;
    UV rank;
    UV size = 1;
    UV i;
    Size_t bytes;
    char *storage;
    tensor_header *tensor;
    NV *values = NULL;
    SV *payload;
    SV *object;
  CODE:
    if (!SvROK(shape) || SvTYPE(SvRV(shape)) != SVt_PVAV)
        croak("shape must be an array reference");
    shape_av = (AV *)SvRV(shape);
    rank = av_count(shape_av);

    if (SvROK(data) && SvTYPE(SvRV(data)) == SVt_PVAV)
        data_av = (AV *)SvRV(data);

    for (i = 0; i < rank; i++) {
        SV **value = av_fetch(shape_av, i, 0);
        UV dimension;
        if (!value || !SvOK(*value) || (dimension = SvUV(*value)) == 0)
            croak("shape dimensions must be positive integers");
        if (size > UV_MAX / dimension)
            croak("tensor size overflow");
        size *= dimension;
    }

    if (!tensor_blob_size(rank, size, &bytes))
        croak("tensor blob size overflow");
    Newxz(storage, bytes, char);
    tensor = (tensor_header *)storage;
    tensor->magic = TENSOR_MAGIC;
    tensor->version = TENSOR_VERSION;
    tensor->rank = rank;
    tensor->size = size;

    {
        UV *shape_out = tensor_shape(tensor);
        UV *strides_out = tensor_strides(tensor);
        NV *data_out = tensor_data(tensor);
        UV stride = 1;

        for (i = rank; i-- > 0;) {
            SV **value = av_fetch(shape_av, i, 0);
            shape_out[i] = SvUV(*value);
            strides_out[i] = stride;
            stride *= shape_out[i];
        }

        if (data_av) {
            UV position = 0;
            Newx(values, size, NV);
            SAVEFREEPV(values);
            tensor_copy_array(aTHX_ data_av, tensor, 0, &position, values);
            if (position != size)
                croak("data size does not match tensor shape");
            Copy(values, data_out, size, NV);
        }
        else {
            for (i = 0; i < size; i++)
                data_out[i] = SvNV(data);
        }
    }

    payload = newSV(0);
    sv_usepvn(payload, (char *)tensor, bytes);
    object = newRV_noinc(payload);
    sv_bless(object, gv_stashpv(class, GV_ADD));
    RETVAL = object;
    OUTPUT:
    RETVAL

AV *
strides(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->rank; i++)
        av_push(result, newSVuv(tensor_strides(tensor)[i]));
    RETVAL = result;
  OUTPUT:
    RETVAL

UV
rank(object)
    SV *object
  CODE:
    RETVAL = tensor_from_object(aTHX_ object)->rank;
  OUTPUT:
    RETVAL

UV
size(object)
    SV *object
  CODE:
    RETVAL = tensor_from_object(aTHX_ object)->size;
  OUTPUT:
    RETVAL

AV *
shape(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->rank; i++)
        av_push(result, newSVuv(tensor_shape(tensor)[i]));
    RETVAL = result;
  OUTPUT:
    RETVAL

NV
at(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
    UV index;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    index = tensor_coordinate_index(aTHX_ tensor,
                                    items > 1 ? &ST(1) : NULL, items - 1);
    RETVAL = tensor_data(tensor)[index];
  OUTPUT:
    RETVAL

UV
index(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    RETVAL = tensor_coordinate_index(aTHX_ tensor,
                                     items > 1 ? &ST(1) : NULL, items - 1);
  OUTPUT:
    RETVAL

void
set_at(object, ...)
    SV *object
  PREINIT:
    tensor_header *tensor;
    UV index;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    index = tensor_coordinate_index(aTHX_ tensor,
                                    items > 2 ? &ST(1) : NULL, items - 2);
    tensor_data(tensor)[index] = SvNV(ST(items - 1));

void
set_data(object, data)
    SV *object
    SV *data
  PREINIT:
    tensor_header *tensor;
    AV *data_av;
    UV i;
  CODE:
    if (!SvROK(data) || SvTYPE(SvRV(data)) != SVt_PVAV)
        croak("data must be an array reference");
    tensor = tensor_from_object(aTHX_ object);
    data_av = (AV *)SvRV(data);
    {
        UV position = 0;
        NV *values;
        Newx(values, tensor->size, NV);
        SAVEFREEPV(values);
        tensor_copy_array(aTHX_ data_av, tensor, 0, &position, values);
        if (position != tensor->size)
            croak("data size does not match tensor shape");
        Copy(values, tensor_data(tensor), tensor->size, NV);
    }

AV *
data(object)
    SV *object
  PREINIT:
    tensor_header *tensor;
    AV *result;
    UV i;
  CODE:
    tensor = tensor_from_object(aTHX_ object);
    result = newAV();
    for (i = 0; i < tensor->size; i++)
        av_push(result, newSVnv(tensor_data(tensor)[i]));
    RETVAL = result;
  OUTPUT:
    RETVAL
