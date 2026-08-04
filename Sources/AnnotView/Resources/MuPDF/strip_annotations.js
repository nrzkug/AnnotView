/* Create a presentation copy without native PDF annotation objects. */

if (scriptArgs.length !== 2) {
    throw new Error("usage: strip_annotations.js input.pdf output.pdf");
}

var inputPath = scriptArgs[0];
var outputPath = scriptArgs[1];
var document = mupdf.Document.openDocument(inputPath);
var pageIndex;

for (pageIndex = 0; pageIndex < document.countPages(); ++pageIndex) {
    var page = document.loadPage(pageIndex);
    var annotations = page.getAnnotations();
    var annotationIndex;
    for (annotationIndex = 0; annotationIndex < annotations.length; ++annotationIndex) {
        page.deleteAnnotation(annotations[annotationIndex]);
    }
}

document.save(outputPath, "compress");

