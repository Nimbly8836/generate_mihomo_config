// CodeMirror, copyright (c) by Marijn Haverbeke and others
// Distributed under an MIT license: https://codemirror.net/5/LICENSE
// YAML syntax lint helper powered by js-yaml (https://github.com/nodeca/js-yaml).

(function (mod) {
  if (typeof exports === 'object' && typeof module === 'object') { // CommonJS
    mod(require('../../lib/codemirror'));
  } else if (typeof define === 'function' && define.amd) { // AMD
    define(['../../lib/codemirror'], mod);
  } else { // Plain browser env
    mod(CodeMirror);
  }
})(function (CodeMirror) {
  'use strict';

  CodeMirror.registerHelper('lint', 'yaml', function (text) {
    var found = [];
    if (!window.jsyaml) return found;
    try {
      window.jsyaml.loadAll(text);
    } catch (error) {
      var mark = error.mark || {};
      var line = typeof mark.line === 'number' ? mark.line : 0;
      var column = typeof mark.column === 'number' ? mark.column : 0;
      var reason = error.reason || error.message || 'YAML 语法错误';
      found.push({
        from: CodeMirror.Pos(line, column),
        to: CodeMirror.Pos(line, column),
        severity: 'error',
        message: reason + '（第 ' + (line + 1) + ' 行，第 ' + (column + 1) + ' 列）'
      });
    }
    return found;
  });
});
