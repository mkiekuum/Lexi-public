#!/usr/bin/env python3
"""Rebuild mislabeled supplemental sections from already-saved XML, never from another dictionary."""
import argparse, collections, json, pathlib, sqlite3, xml.etree.ElementTree as ET
from contextlib import closing
import daijisen_parser as parser

def plan(connection):
    changes = []
    categories = collections.Counter()
    failed = collections.Counter()
    for row in connection.execute("""SELECT id,type,source_entry_id,source_subentry_id,dictionary_raw_xml,dictionary_structured,dictionary_parser_version
        FROM entries WHERE dictionary_raw_xml IS NOT NULL AND dictionary_structured IS NOT NULL AND archive_version IS NULL"""):
        ident, kind, parent, sub, raw, old_json, version = row
        if int(version or 0) >= 8: continue
        if not any(t in raw for t in ('<MUrlG', '<MLocationG', '<MImageG', '補足ロゴ', 'class="C"', 'href="http', 'href="map:')): continue
        try:
            root = ET.fromstring(raw)
            old = json.loads(old_json)
            # Rebuild only from the exact stored article, not the currently connected resource.
            parent_key = str(parent)
            source_kind = 'headword' if kind == 'example' else kind
            key = parent_key + '-' + ('0000' if kind == 'example' else str(sub))
            if parser.local_name(root.tag) != ('SubItem' if source_kind == 'idiom' else 'Contents'):
                raise ValueError('unexpected saved XML root')
            if parser.canonical_source_key(key) != parser.canonical_source_key(str(old.get('sourceEntryID'))+'-'+str(old.get('sourceSubentryID'))):
                raise ValueError('source key mismatch')
            if source_kind == 'idiom' and parser.canonical_source_key(root.get('id','')) != parser.canonical_source_key(key):
                raise ValueError('idiom key mismatch')
            doc = parser._build_document(root,key,source_kind)
            if not doc['plainText'].strip(): raise ValueError('empty body')
            if kind == 'example':
                target = parser.canonical_source_key(parent_key+'-'+str(sub))
                def refs(x):
                    return [s for sec in x['sections'] for s in sec['segments'] if parser.canonical_source_key(s.get('sourceID',''))==target]
                if not refs(doc) or not refs(old): raise ValueError('example reference missing')
            # Do not rewrite ordinary entries merely because their parser version is old.
            def signature(d):
                return [(s['kind'],s['label'],[t.get('target') for t in s['segments'] if (t.get('target') or '').startswith(('http:','https:','map:'))]) for s in d['sections']]
            if signature(old)==signature(doc): continue
            for sec in doc['sections']:
                if sec['label']: categories[sec['label']]+=1
            changes.append((ident,old_json,json.dumps(doc,ensure_ascii=False,sort_keys=True,separators=(',',':')),doc['plainText'],doc['parseStatus']))
        except Exception as e:
            failed[str(e)]+=1
    return changes,categories,failed

def run(db,apply=False,backup=None):
    with closing(sqlite3.connect(db.resolve().as_uri()+'?mode=ro',uri=True)) as c:
        changes,categories,failed=plan(c)
        if apply:
            if not backup or backup.exists() or backup.resolve()==db.resolve(): raise ValueError('new backup path required')
            with closing(sqlite3.connect(backup)) as dest:
                c.backup(dest);dest.commit();dest.execute('PRAGMA journal_mode=DELETE')
                assert dest.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    if apply:
        with closing(sqlite3.connect(db,timeout=10)) as c:
            c.execute('BEGIN IMMEDIATE')
            for ident,old,new,text,status in changes:
                result=c.execute("""UPDATE entries SET dictionary_structured=?,dictionary_text=?,dictionary_search_text=?,dictionary_parser_version='8',dictionary_parse_status=?,dictionary_parse_error=NULL
                    WHERE id=? AND dictionary_structured=?""",(new,text,text,status,ident,old))
                if result.rowcount!=1:raise RuntimeError('entry changed during repair')
            c.commit()
    return {'changed_entries':len(changes),'labels':dict(categories),'skipped_validation':dict(failed),'applied':apply}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--db',required=True,type=pathlib.Path);p.add_argument('--apply',action='store_true');p.add_argument('--backup',type=pathlib.Path);a=p.parse_args()
    print(json.dumps(run(a.db,a.apply,a.backup),ensure_ascii=False,indent=2))
