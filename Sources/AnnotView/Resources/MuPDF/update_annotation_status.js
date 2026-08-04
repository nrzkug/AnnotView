/* Write Acrobat-compatible annotation review state to a new PDF. */

if (scriptArgs.length !== 5) {
    throw new Error("usage: update_annotation_status.js input.pdf output.pdf object stateModel state");
}

var inputPath = scriptArgs[0];
var outputPath = scriptArgs[1];
var targetID = scriptArgs[2];
var stateModel = scriptArgs[3];
var state = scriptArgs[4];
var document = mupdf.Document.openDocument(inputPath);
var found = false;
var pageIndex;

for (pageIndex = 0; pageIndex < document.countPages(); ++pageIndex) {
    var annotations = document.loadPage(pageIndex).getAnnotations();
    var annotationIndex;
    for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
        var object = annotations[annotationIndex].getObject();
        if (object.isIndirect() && String(object.asIndirect()) === targetID) {
            object.put("StateModel", document.newName(stateModel));
            object.put("State", document.newName(state));
            found = true;
        }
    }
}

if (!found) throw new Error("annotation object " + targetID + " was not found");
// Preserve object numbers so additional edits can target the same open model.
document.save(outputPath, "compress");
