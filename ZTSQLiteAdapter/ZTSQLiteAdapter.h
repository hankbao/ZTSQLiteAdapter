//
//  ZTSQLiteAdapter.h
//  ZTSQLiteAdapter
//
//  Created by Hank Bao on 15/4/15.
//  Copyright (c) 2015 zTap studio. All rights reserved.
//

@import Foundation;
@import Mantle;

//! Project version number for ZTSQLiteAdapter.
FOUNDATION_EXPORT double ZTSQLiteAdapterVersionNumber;

//! Project version string for ZTSQLiteAdapter.
FOUNDATION_EXPORT const unsigned char ZTSQLiteAdapterVersionString[];

@protocol MTLModel;

@protocol ZTSQLiteSerializing <MTLModel>
@required

/// Specifies how to map property keys to different column names in SQLite statement.
///
/// Subclasses overriding this method should combine their values with those of
/// `super`.
///
/// Any keys omitted will not participate in SQLite serialization.
+ (NSDictionary *)SQLiteColumnNamesByPropertyKey;

@optional

/// Specifies how to map property keys to different column names in SQLite statement.
///
/// Subclasses overriding this method should combine their values with those of
/// `super`.
///
/// Any keys omitted will not participate in SQLite serialization.
+ (NSDictionary *)SQLiteColumnDefinitionsByPropertyKey;

/// Specifies property keys as primary keys to identify the object in a SQL statement
///
/// Returns a set of property keys.
+ (NSSet *)propertyKeysForPrimaryKeys;

/// Specifies how to convert a SQLite column value to the given property key. If
/// reversible, the transformer will also be used to convert the property value
/// back to a value used in a SQLite statement.
///
/// If the receiver implements a `+<key>SQLiteColumnTransformer` method, ZTSQLiteAdapter
/// will use the result of that method instead.
///
/// Returns a value transformer, or nil if no transformation should be performed.
+ (NSValueTransformer *)SQLiteColumnTransformerForKey:(NSString *)key;

/// Overridden to parse the receiver as a different class, based on information
/// in the provided dictionary.
///
/// This is mostly useful for class clusters, where the abstract base class would
/// be passed into -[ZTSQLiteAdapter initWithModelClass:], but
/// a subclass should be instantiated instead.
///
/// resultDictionary - The SQLite result dictionary that will be parsed.
///
/// Returns the class that should be parsed (which may be the receiver), or nil
/// to abort parsing (e.g., if the data is invalid).
+ (Class)classForParsingResultDictionary:(NSDictionary *)resultDictionary;

@end

/// The domain for errors originating from ZTSQLiteAdapter.
extern NSString * const ZTSQLiteAdapterErrorDomain;

/// +classForParsingResultDictionary: returned nil for the given dictionary.
extern const NSInteger ZTSQLiteAdapterErrorNoClassFound;

/// Converts a MTLModel object to SQLite parameter dictionary (like in FMDB) with optional statement
/// and from a SQLite result dictionary (like in FMDB).
@interface ZTSQLiteAdapter : NSObject

/// Attempts to parse a SQLite result dictionary into a model object.
///
/// modelClass          - The MTLModel subclass to attempt to parse from the JSON.
///                       This class must conform to <ZTSQLiteSerializing>. This
///                       argument must not be nil.
/// resultDictionary    - A SQLite result dictionary return by a query. If this argument is
///                       nil, the method returns nil.
/// error               - If not NULL, this may be set to an error that occurs during
///                       parsing or initializing an instance of `modelClass`.
///
/// Returns an instance of `modelClass` upon success, or nil if a parsing error
/// occurred.
+ (id)modelOfClass:(Class)modelClass fromResultDictionary:(NSDictionary *)resultDictionary error:(NSError **)error;

/// Converts a model into SQLite parameter dictionary representation.
///
/// model - The model to use for INSERT statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite INSERT statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model insertingIntoTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Converts a model into SQLite parameter dictionary representation.
///
/// model - The model to use for INSERT statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite UPDATE statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model updatingInTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Converts a model into SQLite parameter dictionary representation.
///
/// model - The model to use for DELETE statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite DELETE statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model deletingFromTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Attempts to parse a model to get column definition clause used in CREATE / ALTER statements
///
/// modelClass     - The MTLModel subclass to attempt to parse from the JSON.
///                  This class must conform to <ZTSQLiteSerializing> and implement
///                  +SQLiteColumnDefinitionsByPropertyKey. This argument must not be nil.
///
/// Returns a SQLite column definition clause, or nil if an error occurred.
+ (NSString *)columnDefinitionsOfClass:(Class)modelClass;

/// Initializes the receiver with a given model class.
///
/// modelClass - The MTLModel subclass to attempt to parse from the SQLite result dictionary
///              and back. This class must conform to <ZTSQLiteSerializing>. This
///              argument must not be nil.
///
/// Returns an initialized adapter.
- (instancetype)initWithModelClass:(Class)modelClass;

/// Deserializes a model from a SQLite result dictionary.
///
/// The adapter will call -validate: on the model and consider it an error if the
/// validation fails.
///
/// resultDictionary    - A result dictionary. This argument must not be nil.
/// error               - If not NULL, this may be set to an error that occurs during
///                       deserializing or validation.
///
/// Returns a model object, or nil if a deserialization error occurred or the
/// model did not validate successfully.
- (id)modelFromResultDictionary:(NSDictionary *)resultDictionary error:(NSError **)error;

/// Serializes a model into SQLite parameter dictionary representation.
///
/// model - The model to use for INSERT statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite INSERT statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model insertingIntoTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Serializes a model into SQLite parameter dictionary representation.
///
/// model - The model to use for INSERT statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite UPDATE statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model updatingInTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Serializes a model into SQLite parameter dictionary representation.
///
/// model - The model to use for DELETE statement serialization. This argument must not be nil.
/// tableName - The name of a table the statement will be executed on. This argument must not be nil.
/// statement - If not NULL, this may be set to a SQLite DELETE statement.
/// error - If not NULL, this may be set to an error that occurs during serializing.
///
/// Returns a SQLite parameter dictionary representation, or nil if a serialization error occurred.
- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model deletingFromTable:(NSString *)tableName statement:(NSString **)statement error:(NSError **)error;

/// Filters the property keys used to insert a given model.
///
/// propertyKeys - The property keys for which `model` provides a mapping.
/// model        - The model being inserted.
///
/// Subclasses may override this method to determine which property keys should
/// be used when serializing `model`. For instance, this method can be used to
/// create more efficient updates of server-side resources.
///
/// The default implementation simply returns `propertyKeys`.
///
/// Returns a subset of propertyKeys that should be inserted for a given
/// model.
- (NSSet *)insertablePropertyKeys:(NSSet *)propertyKeys forModel:(id<ZTSQLiteSerializing>)model;

/// Filters the property keys used to update a given model.
///
/// propertyKeys - The property keys for which `model` provides a mapping.
/// model        - The model being updated.
///
/// Subclasses may override this method to determine which property keys should
/// be used when serializing `model`. For instance, this method can be used to
/// create more efficient updates of server-side resources.
///
/// The default implementation simply returns `propertyKeys` minus keys mapped by `propertyKeysForPrimaryKeys`.
///
/// Returns a subset of propertyKeys that should be updated for a given
/// model.
- (NSSet *)updatablePropertyKeys:(NSSet *)propertyKeys forModel:(id<ZTSQLiteSerializing>)model;

/// An optional value transformer that should be used for properties of the given
/// class.
///
/// A value transformer returned by the model's +columnTransformerForKey: method
/// is given precedence over the one returned by this method.
///
/// The default implementation invokes `+<class>columnTransformer` on the
/// receiver if it's implemented.
///
/// modelClass - The class of the property to serialize. This property must not be
///              nil.
///
/// Returns a value transformer or nil if no transformation should be used.
+ (NSValueTransformer *)transformerForModelPropertiesOfClass:(Class)modelClass;

/// A value transformer that should be used for a properties of the given
/// primitive type.
///
/// If `objCType` matches @encode(id), the value transformer returned by
/// +transformerForModelPropertiesOfClass: is used instead.
///
/// The default implementation transforms properties that match @encode(BOOL)
/// using the MTLBooleanValueTransformerName transformer.
///
/// objCType - The type encoding for the value of this property. This is the type
///            as it would be returned by the @encode() directive.
///
/// Returns a value transformer or nil if no transformation should be used.
+ (NSValueTransformer *)transformerForModelPropertiesOfObjCType:(const char *)objCType;

@end

@interface ZTSQLiteAdapter (Deprecated)

- (instancetype)init __attribute__((unavailable("Use one of convenience methods instead")));

@end
