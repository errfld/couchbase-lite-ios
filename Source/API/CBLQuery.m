//
//  CBLQuery.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 6/18/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "CouchbaseLitePrivate.h"
#import "CBLView+Internal.h"
#import "CBLDatabase.h"


@interface CBLQueryEnumerator ()
- (instancetype) initWithDatabase: (CBLDatabase*)db rows: (NSArray*)rows;
@end


@implementation CBLQuery
{
    CBLDatabase* _database;
    CBLView* _view;              // nil for _all_docs query
    BOOL _temporaryView;
    NSUInteger _limit, _skip;
    id _startKey, _endKey;
    NSString* _startKeyDocID;
    NSString* _endKeyDocID;
    CBLStaleness _stale;
    BOOL _descending, _prefetch, _sequences, _mapOnly;
    NSArray *_keys;
    NSUInteger _groupLevel;
    SInt64 _lastSequence;
    CBLStatus _status;
}


// A nil view refers to 'all documents'
- (instancetype) initWithDatabase: (CBLDatabase*)database view: (CBLView*)view {
    self = [super init];
    if (self) {
        _database = database;
        _view = view;
        _limit = kDefaultCBLQueryOptions.limit;  // this has a nonzero default (UINT_MAX)
    }
    return self;
}


- (instancetype) initWithDatabase: (CBLDatabase*)database mapBlock: (CBLMapBlock)mapBlock {
    CBLView* view = [database makeAnonymousView];
    if (self = [self initWithDatabase: database view: view]) {
        _temporaryView = YES;
        [view setMapBlock: mapBlock reduceBlock: nil version: @""];
    }
    return self;
}


- (instancetype) initWithQuery: (CBLQuery*)query {
    self = [self initWithDatabase: query->_database view: query->_view];
    if (self) {
        _limit = query.limit;
        _skip = query.skip;
        self.startKey = query.startKey;
        self.endKey = query.endKey;
        _descending = query.descending;
        _prefetch = query.prefetch;
        self.keys = query.keys;
        _groupLevel = query.groupLevel;
        _mapOnly = query.mapOnly;
        self.startKeyDocID = query.startKeyDocID;
        self.endKeyDocID = query.endKeyDocID;
        _stale = query.stale;
        
    }
    return self;
}


- (void) dealloc
{
    if (_temporaryView)
        [_view deleteView];
}


@synthesize  limit=_limit, skip=_skip, descending=_descending, startKey=_startKey, endKey=_endKey,
            prefetch=_prefetch, keys=_keys, groupLevel=_groupLevel, startKeyDocID=_startKeyDocID,
            endKeyDocID=_endKeyDocID, stale=_stale, sequences=_sequences, mapOnly=_mapOnly,
            database=_database;


- (CBLLiveQuery*) asLiveQuery {
    return [[CBLLiveQuery alloc] initWithQuery: self];
}


- (CBLQueryEnumerator*) rows {
    CBLQueryOptions options = {
        .startKey = _startKey,
        .endKey = _endKey,
        .keys = _keys,
        .skip = (unsigned)_skip,
        .limit = (unsigned)_limit,
        .reduce = !_mapOnly && _view.reduceBlock != nil,
        .groupLevel = (unsigned)_groupLevel,
        .descending = _descending,
        .includeDocs = _prefetch,
        .updateSeq = YES,
        .localSeq = _sequences,
        .inclusiveEnd = YES,
    };
    
    NSArray* rows;
    SequenceNumber lastSequence;
    if (_view) {
        lastSequence = _view.lastSequenceIndexed;
        if (_stale == kCBLStaleNever || lastSequence <= 0) {
            _status = [_view updateIndex];
            if (CBLStatusIsError(_status)) {
                Warn(@"Failed to update view index: %d", _status);
                return nil;
            }
            lastSequence = _view.lastSequenceIndexed;
        }
        rows = [_view _queryWithOptions: &options status: &_status];
        // TODO: Implement kCBLStaleUpdateAfter
        
    } else {
        rows = [_database getAllDocs: &options];
        _status = rows ? kCBLStatusOK :kCBLStatusDBError; //FIX: getALlDocs should return status
        lastSequence = _database.lastSequenceNumber;
    }

    if (!rows)
        return nil;
    
    _lastSequence = lastSequence;
    return [[CBLQueryEnumerator alloc] initWithDatabase: _database rows: rows];
}


- (NSError*) error {
    return CBLStatusIsError(_status) ? CBLStatusToNSError(_status, nil) : nil;
}


- (CBLQueryEnumerator*) rowsIfChanged {
    if (_database.lastSequenceNumber == _lastSequence)
        return nil;
    return self.rows;
}


@end




@implementation CBLLiveQuery
{
    BOOL _observing, _updating;
    CBLQueryEnumerator* _rows;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (CBLQueryEnumerator*) rows {
    if (!_observing) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver: self 
                                                 selector: @selector(databaseChanged)
                                                     name: kCBLDatabaseChangeNotification 
                                                   object: self.database];
    }
    if (!_rows) {
        _rows = super.rows;
        Log(@"CBLLiveQuery: Initial row count is %lu", (unsigned long)_rows.count);
    }
    // Have to return a copy because the enumeration has to start at item #0 every time
    return [_rows copy];
}


- (void) setRows:(CBLQueryEnumerator *)rows {
    _rows = rows;
}


- (void) databaseChanged {
    if (!_updating) {
        _updating = YES;
        [self performSelector: @selector(update) withObject: nil afterDelay: 0.0];
    }
}


- (void) update {
    _updating = NO;
    CBLQueryEnumerator* rows = super.rows;
    if (rows && ![rows isEqual: _rows]) {
        Log(@"CBLLiveQuery: ...Rows changed! (now %lu)", (unsigned long)rows.count);
        self.rows = rows;   // Triggers KVO notification
    }
}


@end




@implementation CBLQueryEnumerator
{
    CBLDatabase* _database;
    NSArray* _rows;
    NSUInteger _nextRow;
    NSUInteger _sequenceNumber;
}


@synthesize sequenceNumber=_sequenceNumber;


- (instancetype) initWithDatabase: (CBLDatabase*)database
                             rows: (NSArray*)rows
{
    NSParameterAssert(database);
    self = [super init];
    if (self ) {
        if (!rows)
            return nil;
        _database = database;
        _rows = rows;
    }
    return self;
}


- (id) copyWithZone: (NSZone*)zone {
    return [[[self class] alloc] initWithDatabase: _database
                                             rows: _rows];
}


- (BOOL) isEqual:(id)object {
    if (object == self)
        return YES;
    if (![object isKindOfClass: [CBLQueryEnumerator class]])
        return NO;
    CBLQueryEnumerator* otherEnum = object;
    return [otherEnum->_rows isEqual: _rows];
}


- (NSUInteger) count {
    return _rows.count;
}


- (CBLQueryRow*) rowAtIndex: (NSUInteger)index {
    return _rows[index];
}


- (CBLQueryRow*) nextRow {
    if (_nextRow >= _rows.count)
        return nil;
    return [self rowAtIndex:_nextRow++];
}


- (id) nextObject {
    return [self nextRow];
}


@end




static id fromJSON( NSData* json ) {
    if (!json)
        return nil;
    return [CBLJSON JSONObjectWithData: json
                               options: CBLJSONReadingAllowFragments
                                 error: NULL];
}




@implementation CBLQueryRow
{
    CBLDatabase* _database;
    id _key, _value;            // Usually starts as JSON NSData; parsed on demand
    NSString* _sourceDocID;
    NSDictionary* _documentProperties;
}


@synthesize documentProperties=_documentProperties, sourceDocumentID=_sourceDocID;


- (instancetype) initWithDatabase: (CBLDatabase*)database
                            docID: (NSString*)docID
                              key: (id)key
                            value: (id)value
                    docProperties: (NSDictionary*)docProperties
{
    self = [super init];
    if (self) {
        _database = database;
        _sourceDocID = [docID copy];
        _key = [key copy];
        _value = [value copy];
        _documentProperties = [docProperties copy];
    }
    return self;
}


- (id) key {
    if ([_key isKindOfClass: [NSData class]])
        _key = fromJSON(_key);
    return _key;
}

- (id) value {
    if ([_value isKindOfClass: [NSData class]])
        _value = fromJSON(_value);
    return _value;
}


- (NSString*) documentID {
    // _documentProperties may have been 'redirected' from a different document
    return _documentProperties[@"_id"] ?: _sourceDocID;
}


- (NSString*) documentRevision {
    // Get the revision id from either the embedded document contents,
    // or the '_rev' or 'rev' value key:
    NSString* rev = _documentProperties[@"_rev"];
    if (!rev) {
        id value = self.value;
        if ([value isKindOfClass: [NSDictionary class]]) {      // $castIf would log a warning
            rev = value[@"_rev"];
            if (!rev)
                rev = value[@"rev"];
        }
    }
    
    if (![rev isKindOfClass: [NSString class]])                 // $castIf would log a warning
        rev = nil;
    return rev;
}


- (id) keyAtIndex: (NSUInteger)index {
    id key = self.key;
    if ([key isKindOfClass:[NSArray class]])
        return (index < [key count]) ? key[index] : nil;
    else
        return (index == 0) ? key : nil;
}

- (id) key0                         {return [self keyAtIndex: 0];}
- (id) key1                         {return [self keyAtIndex: 1];}
- (id) key2                         {return [self keyAtIndex: 2];}
- (id) key3                         {return [self keyAtIndex: 3];}


- (CBLDocument*) document {
    NSString* docID = self.documentID;
    if (!docID)
        return nil;
    CBLDocument* doc = [_database documentWithID: docID];
    [doc loadCurrentRevisionFrom: self];
    return doc;
}


- (UInt64) localSequence {
    id seq = (self.documentProperties)[@"_local_seq"];
    return $castIf(NSNumber, seq).unsignedLongLongValue;
}


// This is used by the router
- (NSDictionary*) asJSONDictionary {
    if (_value || _sourceDocID)
        return $dict({@"key", self.key}, {@"value", self.value}, {@"id", _sourceDocID},
                     {@"doc", _documentProperties});
    else
        return $dict({@"key", self.key}, {@"error", @"not_found"});

}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[key=%@; value=%@; id=%@]",
            [self class],
            [CBLJSON stringWithJSONObject: self.key options: CBLJSONWritingAllowFragments error: nil],
            [CBLJSON stringWithJSONObject: self.value options: CBLJSONWritingAllowFragments error: nil],
            self.documentID];
}


@end
