/*
 * MuPDF annotation bridge. Keep this ECMAScript 5 compatible for `mutool run`.
 * Output coordinates remain in MuPDF page space; Swift applies pageTransform
 * to obtain PDF user space before handing data to PDFKit's coordinate APIs.
 */

if (scriptArgs.length !== 1) {
    throw new Error("usage: annotations.js document.pdf");
}

function copyNumbers(value) {
    var result = [];
    var i;
    for (i = 0; i < value.length; ++i) {
        result.push(Number(value[i]));
    }
    return result;
}

function transformPoint(point, matrix) {
    return [
        point[0] * matrix[0] + point[1] * matrix[2] + matrix[4],
        point[0] * matrix[1] + point[1] * matrix[3] + matrix[5]
    ];
}

function copyQuadPoints(annotation) {
    if (!annotation.hasQuadPoints()) return [];
    var source = annotation.getQuadPoints();
    var result = [];
    var i;
    for (i = 0; i < source.length; ++i) {
        result.push(copyNumbers(source[i]));
    }
    return result;
}

function objectNumber(value) {
    if (value && value.isIndirect && value.isIndirect()) {
        return String(value.asIndirect());
    }
    return null;
}

function optionalDate(value) {
    if (!value || !value.getTime || isNaN(value.getTime())) return null;
    return value.toISOString();
}

function optionalString(value) {
    return value ? String(value) : null;
}

function optionalName(object, key) {
    var value = object.get(key);
    if (!value || (value.isNull && value.isNull())) return null;
    if (value.isName && value.isName()) return String(value.asName());
    return String(value);
}

var document = mupdf.Document.openDocument(scriptArgs[0]);
var output = { version: 1, pages: [] };
var pageIndex;

for (pageIndex = 0; pageIndex < document.countPages(); ++pageIndex) {
    var page = document.loadPage(pageIndex);
    var pageOutput = {
        pageIndex: pageIndex,
        pageTransform: copyNumbers(page.getTransform()),
        pageBounds: copyNumbers(page.getBounds()),
        annotations: []
    };
    var annotations = page.getAnnotations();
    var annotationIndex;

    for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
        var annotation = annotations[annotationIndex];
        var object = annotation.getObject();
        var parent = object.get("IRT");
        var type = annotation.getType();
        var bounds = copyNumbers(annotation.getBounds());
        if (type === "Caret" || type === "Text") {
            // MuPDF's getBounds reports the caret's own 20x14 geometry and the
            // sticky-note icon box rather than the annotation's real /Rect.
            // Read /Rect (PDF user space) and report it in MuPDF page space so
            // callers recover the actual rect.
            var rectObject = object.get("Rect");
            if (rectObject && rectObject.isArray && rectObject.isArray()) {
                var rect = [Number(rectObject[0]), Number(rectObject[1]), Number(rectObject[2]), Number(rectObject[3])];
                var caretInverse = mupdf.Matrix.invert(page.getTransform());
                var p0 = transformPoint([rect[0], rect[1]], caretInverse);
                var p1 = transformPoint([rect[2], rect[3]], caretInverse);
                bounds = [
                    Math.min(p0[0], p1[0]), Math.min(p0[1], p1[1]),
                    Math.max(p0[0], p1[0]), Math.max(p0[1], p1[1])
                ];
            }
        }
        pageOutput.annotations.push({
            sourceID: objectNumber(object),
            inReplyToSourceID: objectNumber(parent),
            type: type,
            bounds: bounds,
            quadPoints: copyQuadPoints(annotation),
            contents: optionalString(annotation.getContents()),
            author: annotation.hasAuthor() ? optionalString(annotation.getAuthor()) : null,
            subject: annotation.hasSubject() ? optionalString(annotation.getSubject()) : null,
            creationDate: optionalDate(annotation.getCreationDate()),
            modificationDate: optionalDate(annotation.getModificationDate()),
            color: copyNumbers(annotation.getColor()),
            opacity: Number(annotation.getOpacity()),
            stateModel: optionalName(object, "StateModel"),
            state: optionalName(object, "State")
        });
    }
    output.pages.push(pageOutput);
}

print(JSON.stringify(output));
