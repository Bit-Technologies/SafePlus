#!/usr/bin/env python
# coding: utf8

#####################################################################################
#                 SMC Wizard - Documentation Files Compiler                         #
#                                                                                   #
#                 Copyright (C) 2015, SageMathCloud Authors                         #
#                                                                                   #
#  Distributed under the terms of the GNU General Public License (GPL), version 2+  #
#                                                                                   #
#                        http://www.gnu.org/licenses/                               #
#####################################################################################

import sys
from os.path import abspath, normpath, exists, join
from os import makedirs, walk
from shutil import rmtree
import yaml
import json
import re
from codecs import open
from collections import defaultdict

""" # TODO enable hashtags later
hashtag_re = re.compile(r'#([a-zA-Z].+?\b)')
def process_hashtags(match):
    ht = match.group(1)
    return "<a class='smc-wizard-hashtag' href='{0}'>#{0}</a>".format(ht)
"""

def process_category(doc):
    cats = doc["category"]
    if isinstance(cats, (list, tuple)):
        assert len(cats) == 2
    elif isinstance(cats, basestring):
        cats = cats.split("/", 1)
    else:
        raise Exception("What is id '%s' supposed to be?" % cats)
    return [c.strip().title() for c in cats]

def process_doc(doc, input_fn):
    """
    This processes one document entry and returns the suitable datastructure for later conversion to JSON
    """
    #if not all(_ in doc.keys() for _ in ["title", "code", "descr"]):
    #    raise Exception("keyword missing in %s in %s" % (doc, input_fn))
    title       = doc["title"]
    code        = doc["code"]
    description = doc["descr"] # hashtag_re.sub(process_hashtags, doc["descr"])
    body        = [code, description]
    if "attr" in doc:
        body.append(doc["attr"])
    return title, body

def wizard_data(input_dir, output_fn):
    input_dir = abspath(normpath(input_dir))
    wizard_js = abspath(normpath(output_fn))
    #print(input_dir, output_dir)

    # this implicitly defines all known languages
    recursive_dict = lambda : defaultdict(recursive_dict)
    wizard = {
                 "sage":   recursive_dict(),
                 "python": recursive_dict(),
                 "r":      recursive_dict(),
                 "cython": recursive_dict(),
                 "gap":    recursive_dict()
              }

    for root, _, files in walk(input_dir):
        for fn in filter(lambda _ : _.lower().endswith("yaml"), files):
            input_fn = join(root, fn)
            data = yaml.load_all(open(input_fn, "r", "utf8").read())

            language = entries = lvl1 = lvl2 = titles = None # must be set first in the "category" case

            for doc in data:
                if doc is None:
                    continue

                processed = False

                if "language" in doc:
                    language = doc["language"]
                    if language not in wizard.keys():
                        raise Exception("Language %s not known. Fix first document in %s" % (language, input_fn))
                    processed = True

                if "category" in doc: # setting both levels of the category and re-setting entries and titles
                    lvl1, lvl2 = process_category(doc)
                    if lvl2 in wizard[language][lvl1]:
                        raise Exception("Category level2 '%s' already exists (error in %s)" % (lvl2, input_fn))
                    entries = wizard[language][lvl1][lvl2] = []
                    titles = set()
                    processed = True

                if all(_ in doc.keys() for _ in ["title", "code", "descr"]):
                    # we have an actual document entry, append it in the original ordering as a tuple.
                    title, body = process_doc(doc, input_fn)
                    if title in titles:
                        raise Exception("Duplicate title '{title}' in {language}::{lvl1}/{lvl2} of {input_fn}".format(**locals()))
                    entries.append([title, body])
                    titles.add(title)
                    processed = True

                if not processed: # bad document
                    raise Exception("This document is not well formatted (wrong keys, etc.)\n%s" % doc)

    #from datetime import datetime
    #wizard["timestamp"] = str(datetime.utcnow())
    with open(wizard_js, "w", "utf8") as f_out:
        # sorted keys to de-randomize output (to keep it in Git)
        json.dump(wizard, f_out, ensure_ascii=True, sort_keys=True)
    #return json.dumps(wizard, indent=1)

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: %s <input-directory of *.yaml files> <ouput-file (usually 'wizard.js')>" % sys.argv[0])
        sys.exit(1)
    wizard_data(sys.argv[1], sys.argv[2])
