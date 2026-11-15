import assert from 'node:assert/strict';
import fs from 'node:fs';

// Patch only the gallery into either the rendered page or the QnSub template.
const [inputPath, sourcePath, outputPath] = process.argv.slice(2);
assert(inputPath && sourcePath && outputPath);
const input = fs.readFileSync(inputPath, 'utf8');
const source = fs.readFileSync(sourcePath, 'utf8');
const link = /^ +<a href="#screenshots"[^\n]*<\/a>\n/gm;
const gallery = /^ +<section id="screenshots"[\s\S]*?^ {8}<\/section>\n\n/gm;
const history = /^ +<a href="#history"[^\n]*<\/a>\n/gm;
const workflow = /^ +<!-- Workflow Section -->\n/gm;

function exactlyOne(html, pattern) {
  const matches = [...html.matchAll(pattern)];
  assert.equal(matches.length, 1, `Expected one match for ${pattern}`);
  return matches[0][0];
}

const galleryLink = exactlyOne(source, link);
const gallerySection = exactlyOne(source, gallery);
assert(!gallerySection.includes(' th:'), 'Gallery must work in rendered HTML');
const withoutGallery = input.replace(link, '').replace(gallery, '');
const output = withoutGallery
  .replace(exactlyOne(withoutGallery, history), match => galleryLink + match)
  .replace(exactlyOne(withoutGallery, workflow), match => gallerySection + match);
assert.equal(output.replace(link, '').replace(gallery, ''), withoutGallery);
fs.writeFileSync(outputPath, output);
