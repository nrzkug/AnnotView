/* Create, update and delete Acrobat-compatible PDF annotations. ES5 for mutool run. */

if (scriptArgs.length !== 3) {
    throw new Error("usage: write_annotation.js input.pdf output.pdf annotation.json");
}

var inputPath = scriptArgs[0];
var outputPath = scriptArgs[1];
var payload = JSON.parse(read(scriptArgs[2]));
if (payload.version !== 2 || !Array.isArray(payload.operations)) {
    throw new Error("unsupported annotation payload version");
}

function transformPoint(point, matrix) {
    return [
        point[0] * matrix[0] + point[1] * matrix[2] + matrix[4],
        point[0] * matrix[1] + point[1] * matrix[3] + matrix[5]
    ];
}

function toMuPDFQuad(values, inversePageTransform) {
    if (!values || values.length !== 8) throw new Error("a quad must contain eight numbers");
    var points = [];
    var index;
    for (index = 0; index < 8; index += 2) {
        points.push(transformPoint([Number(values[index]), Number(values[index + 1])], inversePageTransform));
    }
    var xs = points.map(function (point) { return point[0]; });
    var ys = points.map(function (point) { return point[1]; });
    var left = Math.min.apply(Math, xs);
    var right = Math.max.apply(Math, xs);
    var top = Math.min.apply(Math, ys);
    var bottom = Math.max.apply(Math, ys);
    return [left, top, right, top, left, bottom, right, bottom];
}

function pdfDateString(date) {
    function pad(value) { return (value < 10 ? "0" : "") + value; }
    return "D:" + date.getUTCFullYear() + pad(date.getUTCMonth() + 1) +
        pad(date.getUTCDate()) + pad(date.getUTCHours()) +
        pad(date.getUTCMinutes()) + pad(date.getUTCSeconds()) + "Z";
}

function setCommonFields(annotation, name, author, contents, timestamp, color, opacity) {
    var date = new Date(timestamp);
    if (isNaN(date.getTime())) throw new Error("invalid annotation timestamp");
    annotation.setFlags(annotation.getType() === "Text" ? 28 : 4);
    annotation.setName(name);
    annotation.setAuthor(author || "");
    annotation.setContents(contents || "");
    annotation.setColor(color || [1, 0.819608, 0]);
    annotation.setOpacity(opacity === undefined ? 1 : Number(opacity));
    annotation.setCreationDate(date);
    annotation.setModificationDate(date);
}

function finishAppearance(annotation, opacity) {
    annotation.update();
    annotation.getObject().put("CA", opacity === undefined ? 1 : Number(opacity));
}

function findAnnotation(document, sourceID) {
    var pageIndex;
    for (pageIndex = 0; pageIndex < document.countPages(); ++pageIndex) {
        var page = document.loadPage(pageIndex);
        var annotations = page.getAnnotations();
        var annotationIndex;
        for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
            var object = annotations[annotationIndex].getObject();
            if (object.isIndirect() && String(object.asIndirect()) === sourceID) {
                return { page: page, annotation: annotations[annotationIndex] };
            }
        }
    }
    throw new Error("annotation object " + sourceID + " was not found");
}

var document = mupdf.Document.openDocument(inputPath);

function applyOperation(operation) {
    if (operation.operation === "createMarkup") {
    var pagePayloadIndex;
    for (pagePayloadIndex = 0; pagePayloadIndex < operation.pages.length; ++pagePayloadIndex) {
        var pagePayload = operation.pages[pagePayloadIndex];
        if (pagePayload.pageIndex < 0 || pagePayload.pageIndex >= document.countPages()) {
            throw new Error("page index out of range: " + pagePayload.pageIndex);
        }
        var page = document.loadPage(pagePayload.pageIndex);
        var inverse = mupdf.Matrix.invert(page.getTransform());
        var quads = pagePayload.quads.map(function (quad) { return toMuPDFQuad(quad, inverse); });
        if (quads.length === 0) continue;
        var markup = page.createAnnotation(operation.subtype);
        markup.setQuadPoints(quads);
        markup.setSubject(operation.subtype === "StrikeOut" ? "Strikethrough" : operation.subtype);
        setCommonFields(
            markup,
            operation.name + (operation.pages.length > 1 ? "-" + pagePayload.pageIndex : ""),
            operation.author,
            operation.contents,
            operation.timestamp,
            operation.color,
            operation.opacity
        );
        finishAppearance(markup, operation.opacity);
    }
    } else if (operation.operation === "createNote") {
    if (operation.location.pageIndex < 0 || operation.location.pageIndex >= document.countPages()) {
        throw new Error("page index out of range: " + operation.location.pageIndex);
    }
    var notePage = document.loadPage(operation.location.pageIndex);
    var noteInverse = mupdf.Matrix.invert(notePage.getTransform());
    var notePoint = transformPoint(operation.location.point, noteInverse);
    var note = notePage.createAnnotation("Text");
    note.setRect([notePoint[0] - 10, notePoint[1] - 10, notePoint[0] + 10, notePoint[1] + 10]);
    note.setIcon("Comment");
    note.setSubject("Sticky Note");
    note.setIsOpen(false);
    setCommonFields(
        note, operation.name, operation.author, operation.contents,
        operation.timestamp, operation.color, operation.opacity
    );
    finishAppearance(note, operation.opacity);
    } else if (operation.operation === "createCaret") {
    if (operation.location.pageIndex < 0 || operation.location.pageIndex >= document.countPages()) {
        throw new Error("page index out of range: " + operation.location.pageIndex);
    }
    var caretPage = document.loadPage(operation.location.pageIndex);
    var caret = caretPage.createAnnotation("Caret");
    caret.setSubject("InsertedText");
    setCommonFields(
        caret, operation.name, operation.author, operation.contents,
        operation.timestamp, operation.color, operation.opacity
    );
    finishAppearance(caret, operation.opacity);
    // MuPDF normalizes carets to its own 20x14 geometry. Replace it with the
    // exact Acrobat caret: an 8.85x7.2 rect vertically centered on the text
    // baseline, plus Acrobat's leaf-shaped appearance stream and rect dilation.
    var caretObject = caret.getObject();
    caretObject.put("Rect", [
        operation.location.point[0] - 4.4235, operation.location.point[1] - 3.6045,
        operation.location.point[0] + 4.4235, operation.location.point[1] + 3.6045
    ]);
    var caretColor = operation.color || [0.972549, 0.392151, 0.392151];
    var caretGlyph =
        caretColor[0] + " " + caretColor[1] + " " + caretColor[2] + " RG\n" +
        "0.6007 w\n" +
        caretColor[0] + " " + caretColor[1] + " " + caretColor[2] + " rg\n" +
        "0 0 m\n" +
        "3.8227 0 3.8227 3.0035 3.8227 6.007 c\n" +
        "3.8227 3.0035 3.8227 0 7.6454 0 c\n" +
        "h\nf\nS\n";
    var caretGlyphBytes = [];
    var caretGlyphIndex;
    for (caretGlyphIndex = 0; caretGlyphIndex < caretGlyph.length; ++caretGlyphIndex) {
        caretGlyphBytes.push(caretGlyph.charCodeAt(caretGlyphIndex));
    }
    var caretAppearance = document.addStream(caretGlyphBytes);
    caretAppearance.put("Type", "XObject");
    caretAppearance.put("Subtype", "Form");
    caretAppearance.put("FormType", 1);
    caretAppearance.put("BBox", [-0.600708, -0.600708, 8.24606, 6.6077]);
    caretAppearance.put("Matrix", [1, 0, 0, 1, 0.600708, 0.600708]);
    var caretProcSet = document.newArray();
    caretProcSet.push(document.newName("PDF"));
    var caretResources = document.newDictionary();
    caretResources.put("ProcSet", caretProcSet);
    caretAppearance.put("Resources", caretResources);
    var caretAppearanceDict = document.newDictionary();
    caretAppearanceDict.put("N", caretAppearance);
    caretObject.put("AP", caretAppearanceDict);
    caretObject.put("RD", [0.600708, 0.600708, 0.600708, 0.600708]);
    caretObject.delete("CA");
    } else if (operation.operation === "update") {
    var target = findAnnotation(document, operation.sourceID);
    var targetAnnotation = target.annotation;
    // MuPDF normalizes Caret annotations to its own 20x14 geometry whenever
    // finishAppearance runs. Preserve the annotation's real rect and drop the
    // oversized appearance so Acrobat keeps rendering its standard caret.
    var preservedRect = targetAnnotation.getType() === "Caret"
        ? targetAnnotation.getObject().get("Rect") : null;
    targetAnnotation.setAuthor(operation.author || "");
    targetAnnotation.setContents(operation.contents || "");
    targetAnnotation.setColor(operation.color || [1, 0.819608, 0]);
    targetAnnotation.setOpacity(operation.opacity === undefined ? 1 : Number(operation.opacity));
    var modified = new Date(operation.timestamp);
    if (isNaN(modified.getTime())) throw new Error("invalid annotation timestamp");
    targetAnnotation.setModificationDate(modified);
    finishAppearance(targetAnnotation, operation.opacity);
    if (preservedRect) {
        var updatedObject = targetAnnotation.getObject();
        updatedObject.put("Rect", preservedRect);
        updatedObject.delete("AP");
        updatedObject.delete("CA");
    }
    } else if (operation.operation === "move") {
    var moveTarget = findAnnotation(document, operation.sourceID);
    var moveAnnotation = moveTarget.annotation;
    var moveRect = operation.rect;
    if (!moveRect || moveRect.length !== 4) throw new Error("move requires a rect");
    var moveModified = new Date(operation.timestamp);
    if (isNaN(moveModified.getTime())) throw new Error("invalid annotation timestamp");
    // /Rect lives in PDF user space, exactly like the Swift bounds.
    var moveObject = moveAnnotation.getObject();
    if (moveAnnotation.getType() === "Caret") {
        // setModificationDate re-runs MuPDF's caret geometry normalization to
        // 20x14, so write /M directly and apply /Rect last; drop the oversized
        // appearance so Acrobat keeps rendering its standard glyph.
        moveObject.put("M", pdfDateString(moveModified));
        moveObject.put("Rect", [
            Number(moveRect[0]), Number(moveRect[1]),
            Number(moveRect[2]), Number(moveRect[3])
        ]);
        moveObject.delete("AP");
        moveObject.delete("CA");
    } else {
        moveAnnotation.setModificationDate(moveModified);
        // setRect reinterprets coordinates in MuPDF page space and clamps notes
        // back to the icon size; write the exact user-space /Rect instead.
        moveObject.put("Rect", [
            Number(moveRect[0]), Number(moveRect[1]),
            Number(moveRect[2]), Number(moveRect[3])
        ]);
    }
    } else if (operation.operation === "delete") {
    var deletionTarget = findAnnotation(document, operation.sourceID);
    deletionTarget.page.deleteAnnotation(deletionTarget.annotation);
    } else {
        throw new Error("unsupported annotation operation: " + operation.operation);
    }
}

var operationIndex;
for (operationIndex = 0; operationIndex < payload.operations.length; ++operationIndex) {
    applyOperation(payload.operations[operationIndex]);
}

document.save(outputPath, "compress");
