//
//  ZTSQLiteAdapter.m
//  ZTSQLiteAdapter
//
//  Created by Hank Bao on 15/4/15.
//  Copyright (c) 2015 zTap studio. All rights reserved.
//

@import FMDB;

#import "ZTSQLiteAdapter.h"
#import "EXTRuntimeExtensions.h"
#import "EXTScope.h"

NSString * const ZTSQLiteAdapterErrorDomain = @"ZTSQLiteAdapterErrorDomain";
const NSInteger ZTSQLiteAdapterErrorNoClassFound = 2;

// An exception was thrown and caught.
const NSInteger ZTSQLiteAdapterErrorExceptionThrown = 1;

// Associated with the NSException that was caught.
static NSString * const ZTSQLiteAdapterThrownExceptionErrorKey = @"ZTSQLiteAdapterThrownException";

static SEL MTLSelectorWithKeyPattern(NSString *key, const char *suffix) {
    NSUInteger keyLength = [key maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    NSUInteger suffixLength = strlen(suffix);

    char selector[keyLength + suffixLength + 1];

    BOOL success = [key getBytes:selector maxLength:keyLength usedLength:&keyLength encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, key.length) remainingRange:NULL];
    if (!success) return NULL;

    memcpy(selector + keyLength, suffix, suffixLength);
    selector[keyLength + suffixLength] = '\0';

    return sel_registerName(selector);
}

@interface ZTSQLiteAdapter ()

// The MTLModel subclass being parsed, or the class of `model` if parsing has
// completed.
@property (nonatomic, strong, readonly) Class modelClass;

// A cached copy of the return value of +SQLiteColumnNamesByPropertyKey.
@property (nonatomic, copy, readonly) NSDictionary *SQLiteColumnNamesByPropertyKey;

// A cached copy of the return value of -valueTransformersForModelClass:
@property (nonatomic, copy, readonly) NSDictionary *valueTransformersByPropertyKey;

// Used to cache the SQLite adapters returned by -SQLiteAdapterForModelClass:error:.
@property (nonatomic, strong, readonly) NSMapTable *SQLiteAdaptersByModelClass;

// If +classForParsingResultSet: returns a model class different from the
// one this adapter was initialized with, use this method to obtain a cached
// instance of a suitable adapter instead.
//
// modelClass - The class from which to parse the result set. This class must conform
//              to <ZTSQLiteSerializing>. This argument must not be nil.
// error -      If not NULL, this may be set to an error that occurs during
//              initializing the adapter.
//
// Returns a SQLite adapter for modelClass, creating one of necessary. If no
// adapter could be created, nil is returned.
- (ZTSQLiteAdapter *)SQLiteAdapterForModelClass:(Class)modelClass error:(NSError **)error;

// Collect all value transformers needed for a given class.
//
// modelClass - The class from which to parse the SQLite result set. This class must conform
//              to <ZTSQLiteSerializing>. This argument must not be nil.
//
// Returns a dictionary with the properties of modelClass that need
// transformation as keys and the value transformers as values.
+ (NSDictionary *)valueTransformersForModelClass:(Class)modelClass;

@end

@implementation ZTSQLiteAdapter

+ (id)modelOfClass:(Class)modelClass fromResultSet:(FMResultSet *)resultSet error:(NSError *__autoreleasing *)error {
    ZTSQLiteAdapter *adapter = [[self alloc] initWithModelClass:modelClass];
    return [adapter modelFromResultSet:resultSet error:error];
}

+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model insertingIntoTable:(NSString *)tableName
                                     statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    ZTSQLiteAdapter *adapter = [[self alloc] initWithModelClass:model.class];
    return [adapter parameterDictionaryFromModel:model insertingIntoTable:tableName statement:statement error:error];
}

+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model updatingInTable:(NSString *)tableName
                                     statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    ZTSQLiteAdapter *adapter = [[self alloc] initWithModelClass:model.class];
    return [adapter parameterDictionaryFromModel:model updatingInTable:tableName statement:statement error:error];
}

+ (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model deletingFromTable:(NSString *)tableName
                                     statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    ZTSQLiteAdapter *adapter = [[self alloc] initWithModelClass:model.class];
    return [adapter parameterDictionaryFromModel:model deletingFromTable:tableName statement:statement error:error];
}

+ (NSString *)columnDefinitionsOfClass:(Class)modelClass
{
    NSParameterAssert(modelClass);
    NSParameterAssert([modelClass conformsToProtocol:@protocol(ZTSQLiteSerializing)]);

    if (![modelClass respondsToSelector:@selector(SQLiteColumnDefinitionsByPropertyKey)]) {
        return nil;
    }

    __block NSMutableString *defs = nil;
    NSDictionary *columnDefinitionsByPropertyKey = [modelClass SQLiteColumnDefinitionsByPropertyKey];
    [[modelClass SQLiteColumnNamesByPropertyKey] enumerateKeysAndObjectsUsingBlock:^(NSString* propertyKey, NSString* columnName, BOOL *stop) {
        if (!defs) {
            defs = [NSMutableString stringWithFormat:@"(%@", columnName];
        } else {
            [defs appendFormat:@", %@", columnName];
        }

        NSString *def = columnDefinitionsByPropertyKey[propertyKey];
        if (def) {
            [defs appendFormat:@" %@", def];
        }
    }];

    [defs appendString:@")"];
    return [defs copy];
}

- (instancetype)initWithModelClass:(Class)modelClass {
    NSParameterAssert(modelClass);
    NSParameterAssert([modelClass conformsToProtocol:@protocol(ZTSQLiteSerializing)]);

    if (self = [super init]) {
        _modelClass = modelClass;
        _SQLiteColumnNamesByPropertyKey = [modelClass SQLiteColumnNamesByPropertyKey];

        NSSet *propertyKeys = [self.modelClass propertyKeys];
        for (NSString *mappedPropertyKey in self.SQLiteColumnNamesByPropertyKey) {
            if (![propertyKeys containsObject:mappedPropertyKey]) {
                NSAssert(NO, @"%@ is not a property of %@.", mappedPropertyKey, modelClass);
                return nil;
            }

            id value = self.SQLiteColumnNamesByPropertyKey[mappedPropertyKey];
            if (![value isKindOfClass:NSString.class]) {
                NSAssert(NO, @"%@ must map to a column name, got: %@.", mappedPropertyKey, value);
                return nil;
            }
        }

        _valueTransformersByPropertyKey = [self.class valueTransformersForModelClass:modelClass];
        _SQLiteAdaptersByModelClass = [NSMapTable strongToStrongObjectsMapTable];
    }
    return self;
}

- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model propertyKeys:(NSSet *)propertyKeys error:(NSError *__autoreleasing *)error {
    NSMutableDictionary *parameterDictionary = [NSMutableDictionary dictionaryWithCapacity:propertyKeys.count];

    __block BOOL success = YES;
    __block NSError *tmpError = nil;

    [propertyKeys enumerateObjectsUsingBlock:^(NSString *propertyKey, BOOL *stop) {
        id value = model.dictionaryValue[propertyKey];

        NSValueTransformer *transformer = self.valueTransformersByPropertyKey[propertyKey];
        if ([transformer.class allowsReverseTransformation]) {
            // Map NSNull -> nil for the transformer, and then back for the
            // dictionaryValue we're going to insert into.
            if (value == [NSNull null]) {
                value = nil;
            }

            if ([transformer respondsToSelector:@selector(reverseTransformedValue:success:error:)]) {
                id<MTLTransformerErrorHandling> errorHandlingTransformer = (id)transformer;

                value = [errorHandlingTransformer reverseTransformedValue:value success:&success error:&tmpError];
                if (!success) {
                    *stop = YES;
                    return;
                }
                value = value ?: [NSNull null];
            } else {
                value = [transformer reverseTransformedValue:value] ?: [NSNull null];
            }
        }

        NSString *key = self.SQLiteColumnNamesByPropertyKey[propertyKey];
        parameterDictionary[key] = value;
    }];

    if (success) {
        return parameterDictionary;
    } else {
        if (error) {
            *error = tmpError;
        }
        return nil;
    }
}

- (NSString *)whereClauseWithColumnNames:(NSArray *)columnNames {
    NSMutableArray *whereComponents = [NSMutableArray arrayWithCapacity:columnNames.count];
    for (NSString *name in columnNames) {
        [whereComponents addObject:[NSString stringWithFormat:@"%@ = :%@", name, name]];
    }
    return [whereComponents componentsJoinedByString:@" AND "];
}

- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model insertingIntoTable:(NSString *)tableName statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    NSParameterAssert(model);
    NSParameterAssert([model isKindOfClass:self.modelClass]);
    NSParameterAssert(tableName);

    if (self.modelClass != model.class) {
        ZTSQLiteAdapter *otherAdapter = [self SQLiteAdapterForModelClass:model.class error:error];
        return [otherAdapter parameterDictionaryFromModel:model insertingIntoTable:tableName statement:statement error:error];
    }

    NSSet *propertyKeysToInsert = [self insertablePropertyKeys:[NSSet setWithArray:self.SQLiteColumnNamesByPropertyKey.allKeys] forModel:model];

    if (statement) {
        NSArray *columnNames = [self.SQLiteColumnNamesByPropertyKey dictionaryWithValuesForKeys:propertyKeysToInsert.allObjects].allValues;
        NSMutableArray *parameters = [NSMutableArray arrayWithCapacity:columnNames.count];
        for (NSString *name in columnNames) {
            [parameters addObject:[NSString stringWithFormat:@":%@", name]];
        }
        *statement = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@);", tableName,
                      [columnNames componentsJoinedByString:@", "], [parameters componentsJoinedByString:@", "]];
    }

    return [self parameterDictionaryFromModel:model propertyKeys:propertyKeysToInsert error:error];
}

- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model updatingInTable:(NSString *)tableName statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    NSParameterAssert(model);
    NSParameterAssert([model isKindOfClass:self.modelClass]);
    NSParameterAssert(tableName);

    if (self.modelClass != model.class) {
        ZTSQLiteAdapter *otherAdapter = [self SQLiteAdapterForModelClass:model.class error:error];
        return [otherAdapter parameterDictionaryFromModel:model updatingInTable:tableName statement:statement error:error];
    }

    NSSet *propertyKeysToUpdating = [self updatablePropertyKeys:[NSSet setWithArray:self.SQLiteColumnNamesByPropertyKey.allKeys] forModel:model];

    if ([model respondsToSelector:@selector(propertyKeysForPrimaryKeys)]) {
        NSSet *propertyKeysForPrimaryKeys = [model propertyKeysForPrimaryKeys];

        if (propertyKeysForPrimaryKeys.count && statement) {
            NSArray *columnsToSet = [self.SQLiteColumnNamesByPropertyKey dictionaryWithValuesForKeys:propertyKeysToUpdating.allObjects].allValues;
            NSMutableArray *setComponents = [NSMutableArray arrayWithCapacity:columnsToSet.count];
            for (NSString *name in columnsToSet) {
                [setComponents addObject:[NSString stringWithFormat:@"%@ = :%@", name, name]];
            }

            NSArray *columnsForWhere = [self.SQLiteColumnNamesByPropertyKey dictionaryWithValuesForKeys:propertyKeysForPrimaryKeys.allObjects].allValues;
            NSString *whereClause = [self whereClauseWithColumnNames:columnsForWhere];

            *statement = [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE %@;", tableName,
                          [setComponents componentsJoinedByString:@", "], whereClause];
        }
    }

    return [self parameterDictionaryFromModel:model propertyKeys:propertyKeysToUpdating error:error];
}

- (NSDictionary *)parameterDictionaryFromModel:(id<ZTSQLiteSerializing>)model deletingFromTable:(NSString *)tableName statement:(NSString *__autoreleasing *)statement error:(NSError *__autoreleasing *)error {
    NSParameterAssert(model);
    NSParameterAssert([model isKindOfClass:self.modelClass]);
    NSParameterAssert(tableName);

    if (self.modelClass != model.class) {
        ZTSQLiteAdapter *otherAdapter = [self SQLiteAdapterForModelClass:model.class error:error];
        return [otherAdapter parameterDictionaryFromModel:model deletingFromTable:tableName statement:statement error:error];
    }

    if ([model respondsToSelector:@selector(propertyKeysForPrimaryKeys)]) {
        NSSet *propertyKeysForPrimaryKeys = [model propertyKeysForPrimaryKeys];

        if (propertyKeysForPrimaryKeys.count) {
            if (statement) {
                NSArray *columnsForWhere = [self.SQLiteColumnNamesByPropertyKey dictionaryWithValuesForKeys:propertyKeysForPrimaryKeys.allObjects].allValues;
                NSString *whereClause = [self whereClauseWithColumnNames:columnsForWhere];

                *statement = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@;", tableName, whereClause];
            }

            return [self parameterDictionaryFromModel:model propertyKeys:propertyKeysForPrimaryKeys error:error];
        }
    }

    return nil;
}

- (id)modelFromResultSet:(FMResultSet *)resultSet error:(NSError *__autoreleasing *)error {
    NSParameterAssert(resultSet);
    if (!resultSet) {
        return nil;
    }

    if ([self.modelClass respondsToSelector:@selector(classForParsingResultSet:)]) {
        Class class = [self.modelClass classForParsingResultSet:resultSet];
        if (!class) {
            if (error) {
                NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: NSLocalizedString(@"Cloud not parse SQLite result set", @""),
                                            NSLocalizedFailureReasonErrorKey: NSLocalizedString(@"No model class could be found to parse the SQLite result set.", @"")
                                            };

                *error = [NSError errorWithDomain:ZTSQLiteAdapterErrorDomain code:ZTSQLiteAdapterErrorNoClassFound userInfo:userInfo];
            }

            return nil;
        }

        if (class != self.modelClass) {
            NSAssert([class conformsToProtocol:@protocol(ZTSQLiteSerializing)], @"Class %@ returned from +classForParsingResultSet: does not conform to <ZTSQLiteSerializing>", class);

            ZTSQLiteAdapter *otherAdapter = [self SQLiteAdapterForModelClass:class error:error];

            return [otherAdapter modelFromResultSet:resultSet error:error];
        }
    }

    NSMutableDictionary *dictionaryValue = [NSMutableDictionary dictionaryWithCapacity:resultSet.columnCount];

    for (NSString *propertyKey in [self.modelClass propertyKeys]) {
        NSString *columnName = self.SQLiteColumnNamesByPropertyKey[propertyKey];
        if (!columnName) {
            continue;
        }

        id value = [resultSet objectForColumnName:columnName];

        @try {
            NSValueTransformer *transformer = self.valueTransformersByPropertyKey[propertyKey];
            if (transformer) {
                // Map NSNull -> nil for the transformer, and then back for the
                // dictionary we're going to insert into.
                if (value == [NSNull null]) {
                    value = nil;
                }

                if ([transformer respondsToSelector:@selector(transformedValue:success:error:)]) {
                    id<MTLTransformerErrorHandling> errorHandlingTransformer = (id)transformer;

                    BOOL success = YES;
                    value = [errorHandlingTransformer transformedValue:value success:&success error:error];

                    if (!success) {
                        return nil;
                    }
                } else {
                    value = [transformer transformedValue:value];
                }

                if (value == nil) {
                    value = [NSNull null];
                }
            }

            dictionaryValue[propertyKey] = value;
        } @catch (NSException *ex) {
            NSLog(@"*** Caught exception %@ parsing column name \"%@\" from: %@", ex, columnName, resultSet);

            // Fail fast in Debug builds.
            #if DEBUG
            @throw ex;
            #else
            if (error != NULL) {
                NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: ex.description,
                                            NSLocalizedFailureReasonErrorKey: ex.reason,
                                            ZTSQLiteAdapterThrownExceptionErrorKey: ex
                                            };

                *error = [NSError errorWithDomain:ZTSQLiteAdapterErrorDomain code:ZTSQLiteAdapterErrorExceptionThrown userInfo:userInfo];
            }

            return nil;
            #endif
        }
    }

    id model = [self.modelClass modelWithDictionary:dictionaryValue error:error];

    return [model validate:error] ? model : nil;
}

- (NSSet *)insertablePropertyKeys:(NSSet *)propertyKeys forModel:(id<ZTSQLiteSerializing>)model {
    return propertyKeys;
}

- (NSSet *)updatablePropertyKeys:(NSSet *)propertyKeys forModel:(id<ZTSQLiteSerializing>)model {
    if ([model respondsToSelector:@selector(propertyKeysForPrimaryKeys)]) {
        NSMutableSet* keys = [propertyKeys mutableCopy];
        [keys minusSet:[model propertyKeysForPrimaryKeys]];
        return keys;
    }
    return propertyKeys;
}

- (ZTSQLiteAdapter *)SQLiteAdapterForModelClass:(Class)modelClass error:(NSError *__autoreleasing *)error {
    NSParameterAssert(modelClass);
    NSParameterAssert([modelClass conformsToProtocol:@protocol(ZTSQLiteSerializing)]);

    @synchronized(self) {
        ZTSQLiteAdapter *result = [self.SQLiteAdaptersByModelClass objectForKey:modelClass];

        if (result != nil) {
            return result;
        }

        result = [[ZTSQLiteAdapter alloc] initWithModelClass:modelClass];

        if (result != nil) {
            [self.SQLiteAdaptersByModelClass setObject:result forKey:modelClass];
        }

        return result;
    }
}

+ (NSDictionary *)valueTransformersForModelClass:(Class)modelClass {
    NSParameterAssert(modelClass);
    NSParameterAssert([modelClass conformsToProtocol:@protocol(ZTSQLiteSerializing)]);

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    for (NSString *key in [modelClass propertyKeys]) {
        SEL selector = MTLSelectorWithKeyPattern(key, "SQLiteColumnTransformer");
        if ([modelClass respondsToSelector:selector]) {
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[modelClass methodSignatureForSelector:selector]];
            invocation.target = modelClass;
            invocation.selector = selector;
            [invocation invoke];

            __unsafe_unretained id transformer = nil;
            [invocation getReturnValue:&transformer];

            if (transformer != nil) {
                result[key] = transformer;
            }

            continue;
        }

        if ([modelClass respondsToSelector:@selector(SQLiteColumnTransformerForKey:)]) {
            NSValueTransformer *transformer = [modelClass SQLiteColumnTransformerForKey:key];

            if (transformer != nil) {
                result[key] = transformer;
            }

            continue;
        }

        objc_property_t property = class_getProperty(modelClass, key.UTF8String);

        if (property == NULL) continue;

        mtl_propertyAttributes *attributes = mtl_copyPropertyAttributes(property);
        @onExit {
            free(attributes);
        };

        NSValueTransformer *transformer = nil;

        if (*(attributes->type) == *(@encode(id))) {
            Class propertyClass = attributes->objectClass;

            if (propertyClass) {
                transformer = [self transformerForModelPropertiesOfClass:propertyClass];
            }

            if (!transformer) {
                transformer = [NSValueTransformer mtl_validatingTransformerForClass:NSObject.class];
            }
        } else {
            transformer = [self transformerForModelPropertiesOfObjCType:attributes->type] ?: [NSValueTransformer mtl_validatingTransformerForClass:NSValue.class];
        }

        if (transformer) {
            result[key] = transformer;
        }
    }

    return result;
}

+ (NSValueTransformer *)transformerForModelPropertiesOfClass:(Class)modelClass {
    NSParameterAssert(modelClass);

    SEL selector = MTLSelectorWithKeyPattern(NSStringFromClass(modelClass), "SQLiteColumnTransformer");
    if (![self respondsToSelector:selector]) {
        return nil;
    }
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:selector]];
    invocation.target = self;
    invocation.selector = selector;
    [invocation invoke];
    
    __unsafe_unretained id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

+ (NSValueTransformer *)transformerForModelPropertiesOfObjCType:(const char *)objCType {
    NSParameterAssert(objCType);
    
    if (strcmp(objCType, @encode(BOOL)) == 0) {
        return [NSValueTransformer valueTransformerForName:MTLBooleanValueTransformerName];
    }
    
    return nil;
}

@end
