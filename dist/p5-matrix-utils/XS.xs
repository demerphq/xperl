#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef struct {
    UV rank;
    UV size;
    /* Followed by rank UV shape values, rank UV stride values, and size
     * NV data values.  The whole representation is owned by one PV. */
} tensor_header;

static tensor_header *
tensor_from_object(pTHX_ SV *object)
{
    SV *payload;

    if (!SvROK(object) || !SvPOK(SvRV(object)))
        croak("Tensor::XS object expected");

    payload = SvRV(object);
    if (SvCUR(payload) < sizeof(tensor_header))
        croak("invalid Tensor::XS object");

    return (tensor_header *)SvPV_nolen(payload);
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
    return (NV *)(tensor_strides(tensor) + tensor->rank);
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

    if (data_av && av_count(data_av) != size)
        croak("data size does not match tensor shape");

    bytes = sizeof(tensor_header)
        + rank * sizeof(UV) * 2
        + size * sizeof(NV);
    Newxz(storage, bytes, char);
    tensor = (tensor_header *)storage;
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

        for (i = 0; i < size; i++) {
            SV *value = data_av ? *av_fetch(data_av, i, 0) : data;
            data_out[i] = SvNV(value);
        }
    }

    payload = newSV(0);
    sv_usepvn(payload, (char *)tensor, bytes);
    object = newRV_noinc(payload);
    sv_bless(object, gv_stashpv(class, GV_ADD));
    RETVAL = object;
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
at(object, index)
    SV *object
    UV index
  CODE:
    {
        tensor_header *tensor = tensor_from_object(aTHX_ object);
        if (index >= tensor->size)
            croak("tensor index out of bounds");
        RETVAL = tensor_data(tensor)[index];
    }
  OUTPUT:
    RETVAL

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
