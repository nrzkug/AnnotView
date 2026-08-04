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
        annotations: []
    };
    var annotations = page.getAnnotations();
    var annotationIndex;

    for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
        var annotation = annotations[annotationIndex];
        var object = annotation.getObject();
        var parent = object.get("IRT");
        pageOutput.annotations.push({
            sourceID: objectNumber(object),
            inReplyToSourceID: objectNumber(parent),
            type: annotation.getType(),
            bounds: copyNumbers(annotation.getBounds()),
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
