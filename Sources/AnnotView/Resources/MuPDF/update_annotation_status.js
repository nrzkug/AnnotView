/* Write Acrobat-compatible annotation review state to a new PDF. */

if (scriptArgs.length !== 3 && scriptArgs.length !== 5) {
    throw new Error("usage: update_annotation_status.js input.pdf output.pdf statuses.json");
}

var inputPath = scriptArgs[0];
var outputPath = scriptArgs[1];
var updates;
if (scriptArgs.length === 5) {
    // Preserve the original single-status CLI bridge.
    updates = [{ sourceID: scriptArgs[2], stateModel: scriptArgs[3], state: scriptArgs[4] }];
} else {
    var payload = JSON.parse(read(scriptArgs[2]));
    if (payload.version !== 1 || !Array.isArray(payload.updates)) {
        throw new Error("unsupported annotation status payload version");
    }
    updates = payload.updates;
}
var document = mupdf.Document.openDocument(inputPath);
var found = {};
var pageIndex;

for (pageIndex = 0; pageIndex < document.countPages(); ++pageIndex) {
    var annotations = document.loadPage(pageIndex).getAnnotations();
    var annotationIndex;
    for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
        var object = annotations[annotationIndex].getObject();
        if (!object.isIndirect()) continue;
        var objectID = String(object.asIndirect());
        var updateIndex;
        for (updateIndex = 0; updateIndex < updates.length; ++updateIndex) {
            var update = updates[updateIndex];
            if (objectID === update.sourceID) {
                object.put("StateModel", document.newName(update.stateModel));
                object.put("State", document.newName(update.state));
                found[update.sourceID] = true;
            }
        }
    }
}

for (var targetIndex = 0; targetIndex < updates.length; ++targetIndex) {
    var targetID = updates[targetIndex].sourceID;
    if (!found[targetID]) throw new Error("annotation object " + targetID + " was not found");
}
// Preserve object numbers so additional edits can target the same open model.
document.save(outputPath, "compress");
