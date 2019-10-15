//
//  Aspects.m
//  Aspects - A delightful, simple library for aspect oriented programming.
//
//  Copyright (c) 2014 Peter Steinberger. Licensed under the MIT license.
//

#import "Aspects.h"
#import <libkern/OSAtomic.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define AspectLog(...)
//#define AspectLog(...) do { NSLog(__VA_ARGS__); }while(0)
#define AspectLogError(...) do { NSLog(__VA_ARGS__); }while(0)

// Block internals.
typedef NS_OPTIONS(int, AspectBlockFlags) {
	AspectBlockFlagsHasCopyDisposeHelpers = (1 << 25),
	AspectBlockFlagsHasSignature          = (1 << 30)
};
typedef struct _AspectBlock {
	__unused Class isa;
	AspectBlockFlags flags;
	__unused int reserved;
	void (__unused *invoke)(struct _AspectBlock *block, ...);
	struct {
		unsigned long int reserved;
		unsigned long int size;
		// requires AspectBlockFlagsHasCopyDisposeHelpers
		void (*copy)(void *dst, const void *src);
		void (*dispose)(const void *);
		// requires AspectBlockFlagsHasSignature
		const char *signature;
		const char *layout;
	} *descriptor;
	// imported variables
} *AspectBlockRef;

@interface AspectInfo : NSObject <AspectInfo>
- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation;
@property (nonatomic, unsafe_unretained, readonly) id instance;
@property (nonatomic, strong, readonly) NSArray *arguments;
@property (nonatomic, strong, readonly) NSInvocation *originalInvocation;
@end

// Tracks a single aspect.
@interface AspectIdentifier : NSObject
+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error;
- (BOOL)invokeWithInfo:(id<AspectInfo>)info;
@property (nonatomic, assign) SEL selector;
@property (nonatomic, strong) id block;
@property (nonatomic, strong) NSMethodSignature *blockSignature;
@property (nonatomic, weak) id object;
@property (nonatomic, assign) AspectOptions options;
@end

// Tracks all aspects for an object/class.
@interface AspectsContainer : NSObject
- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)injectPosition;
- (BOOL)removeAspect:(id)aspect;
- (BOOL)hasAspects;
@property (atomic, copy) NSArray *beforeAspects;
@property (atomic, copy) NSArray *insteadAspects;
@property (atomic, copy) NSArray *afterAspects;
@end

@interface AspectTracker : NSObject
- (id)initWithTrackedClass:(Class)trackedClass parent:(AspectTracker *)parent;
@property (nonatomic, strong) Class trackedClass;
@property (nonatomic, strong) NSMutableSet *selectorNames;
@property (nonatomic, weak) AspectTracker *parentEntry;
@end

@interface NSInvocation (Aspects)
- (NSArray *)aspects_arguments;
@end

#define AspectPositionFilter 0x07

#define AspectError(errorCode, errorDescription) do { \
AspectLogError(@"Aspects: %@", errorDescription); \
if (error) { *error = [NSError errorWithDomain:AspectErrorDomain code:errorCode userInfo:@{NSLocalizedDescriptionKey: errorDescription}]; }}while(0)

NSString *const AspectErrorDomain = @"AspectErrorDomain";
static NSString *const AspectsSubclassSuffix = @"_Aspects_";
static NSString *const AspectsMessagePrefix = @"aspects_";

@implementation NSObject (Aspects)

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public Aspects API

+ (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add((id)self, selector, options, block, error);
}

/// @return A token which allows to later deregister the aspect.
- (id<AspectToken>)aspect_hookSelector:(SEL)selector
                      withOptions:(AspectOptions)options
                       usingBlock:(id)block
                            error:(NSError **)error {
    return aspect_add(self, selector, options, block, error);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private Helper

static id aspect_add(id self, SEL selector, AspectOptions options, id block, NSError **error) {
    
    // 断言参数不能空指针
    NSCParameterAssert(self);
    NSCParameterAssert(selector);
    NSCParameterAssert(block);
    
    // 添加 __block 关键字是因为块内要修改 identifier，必须添加 否则编译静态检查就不会通过
    __block AspectIdentifier *identifier = nil;
    
    aspect_performLocked(^{
        
        // 字面意思: 是否允许Hook这个selector在当前这个类，这个 aspect_isSelectorAllowedAndTrack 方法做了很多事情
        // 包括: 创建tracker，给tracker添加方法，判断是不是已经hook了这个层级不能再hook 等。
        // 可以点击进去看下，都已经标记注释了。
        if (aspect_isSelectorAllowedAndTrack(self, selector, options, error)) {
            
            // 这里解释两个类 AspectsContainer, AspectIdentifier
            // 从头文件上看，简单的说，AspectsContainer 里面按照 options 分为3个数组，分别是
            // 1.beforeAspects
            // 2.insteadAspects
            // 3.afterAspects
            // 每个数组里面装着很多AspectIdentifier，AspectIdentifier主要包含你hook的回调和方法签名等等，就像变量名一样，是你hook的标识一样。
            // 下面 aspect_getContainerForObject 从当前self里面获取关联对象 AspectsContainer，如果获取不到新创建 AspectsContainer 并且关联 self。
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, selector);
            
            // 字面意思 通过 selector self options block 去创建identifier
            // 实际上:
            // 1. 看下block的签名 和 被hook的原函数方法签名 是否能兼容，具体点进去看下，我都备注了。
            // 2. 创建 AspectIdentifier 对象，挨个属性赋值，然后返回。
            identifier = [AspectIdentifier identifierWithSelector:selector object:self options:options block:block error:error];
            
            // 如果 identifier 存在
            if (identifier) {
                
                // 把 identifier 添加到 aspectContainer 的 beforeAspects insteadAspects afterAspects 这三个数组当中，根据可选项，就是那个 是hook在前，还是在后，还是替换那个。
                [aspectContainer addAspect:identifier withOptions:options];
                
                // Modify the class to allow message interception.
                // 字面意思: 处理class和hook的方法
                aspect_prepareClassAndHookSelector(self, selector, error);
                
            }
            
        }
        
    });
    
    return identifier;
}

static BOOL aspect_remove(AspectIdentifier *aspect, NSError **error) {
    NSCAssert([aspect isKindOfClass:AspectIdentifier.class], @"Must have correct type.");

    __block BOOL success = NO;
    aspect_performLocked(^{
        id self = aspect.object; // strongify
        if (self) {
            AspectsContainer *aspectContainer = aspect_getContainerForObject(self, aspect.selector);
            success = [aspectContainer removeAspect:aspect];

            aspect_cleanupHookedClassAndSelector(self, aspect.selector);
            // destroy token
            aspect.object = nil;
            aspect.block = nil;
            aspect.selector = NULL;
        }else {
            NSString *errrorDesc = [NSString stringWithFormat:@"Unable to deregister hook. Object already deallocated: %@", aspect];
            AspectError(AspectErrorRemoveObjectAlreadyDeallocated, errrorDesc);
        }
    });
    return success;
}

// 参数 dispatch_block_t 描述 The type of blocks submitted to dispatch queues, which take no arguments and have no return value.
// 这个类型的块执行的时候，会自动把执行内容添加到 dispatch queues 里面，所以才有下面的添加自旋锁。
static void aspect_performLocked(dispatch_block_t block) {
    static OSSpinLock aspect_lock = OS_SPINLOCK_INIT;
    OSSpinLockLock(&aspect_lock);
    block();
    OSSpinLockUnlock(&aspect_lock);
}

static SEL aspect_aliasForSelector(SEL selector) {
    NSCParameterAssert(selector);
	return NSSelectorFromString([AspectsMessagePrefix stringByAppendingFormat:@"_%@", NSStringFromSelector(selector)]);
}

static NSMethodSignature *aspect_blockMethodSignature(id block, NSError **error) {
    
    // __bridge 用来和 void* 进行转换
    // AspectBlockRef 是一个结构体，其实呢这个结果体里面大部分属性就是Block的结构，但是
    // AspectBlockRef 对 Block 的结构体进行了拓展一些自己的属性例如 AspectBlockFlags
    // 所以下面的代码 layout 会被 block 赋值，但是里面有些自定义的属性在结构体里面 现在没有值。
    AspectBlockRef layout = (__bridge void *)block;
    
    // 位运算 按位与操作
    // 如果 layout->flags != AspectBlockFlagsHasSignature
	if (!(layout->flags & AspectBlockFlagsHasSignature)) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't contain a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    
    // 获取block的描述指针descriptor
	void *desc = layout->descriptor;
	desc += 2 * sizeof(unsigned long int);
    
	if (layout->flags & AspectBlockFlagsHasCopyDisposeHelpers) {
		desc += 2 * sizeof(void *);
    }
    
	if (!desc) {
        NSString *description = [NSString stringWithFormat:@"The block %@ doesn't has a type signature.", block];
        AspectError(AspectErrorMissingBlockSignature, description);
        return nil;
    }
    
    // 获取匿名函数Block的方法签名
    // 这里的signature是Encode过的签名
	const char *signature = (*(const char **)desc);
	return [NSMethodSignature signatureWithObjCTypes:signature];
}

static BOOL aspect_isCompatibleBlockSignature(NSMethodSignature *blockSignature, id object, SEL selector, NSError **error) {
    
    // 断言参数 blockSignature object selector 不为空
    NSCParameterAssert(blockSignature);
    NSCParameterAssert(object);
    NSCParameterAssert(selector);

    // 解释一下: 下面这些逻辑是 查看我们用aspect进行hook的block的方法签名 能不能 和原函数的方法签名对得上。
    // 当然不是一摸一样，只是比较block的参数是否和hook的参数类型一样，比如参数，返回值这种。
    // 举个例子: 你hook的原方法有一个参数是NSString类型，但是你在hook的block中写的是NSNumber这里肯定不过，返回NO，从而得到签名不匹配。
    BOOL signaturesMatch = YES;
    NSMethodSignature *methodSignature = [[object class] instanceMethodSignatureForSelector:selector];
    if (blockSignature.numberOfArguments > methodSignature.numberOfArguments) {
        signaturesMatch = NO;
    }else {
        if (blockSignature.numberOfArguments > 1) {
            const char *blockType = [blockSignature getArgumentTypeAtIndex:1];
            if (blockType[0] != '@') {
                signaturesMatch = NO;
            }
        }
        // Argument 0 is self/block, argument 1 is SEL or id<AspectInfo>. We start comparing at argument 2.
        // The block can have less arguments than the method, that's ok.
        if (signaturesMatch) {
            for (NSUInteger idx = 2; idx < blockSignature.numberOfArguments; idx++) {
                const char *methodType = [methodSignature getArgumentTypeAtIndex:idx];
                const char *blockType = [blockSignature getArgumentTypeAtIndex:idx];
                // Only compare parameter, not the optional type data.
                if (!methodType || !blockType || methodType[0] != blockType[0]) {
                    signaturesMatch = NO; break;
                }
            }
        }
    }

    if (!signaturesMatch) {
        NSString *description = [NSString stringWithFormat:@"Blog signature %@ doesn't match %@.", blockSignature, methodSignature];
        AspectError(AspectErrorIncompatibleBlockSignature, description);
        return NO;
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class + Selector Preparation

static BOOL aspect_isMsgForwardIMP(IMP impl) {
    return impl == _objc_msgForward
#if !defined(__arm64__)
    || impl == (IMP)_objc_msgForward_stret
#endif
    ;
}

static IMP aspect_getMsgForwardIMP(NSObject *self, SEL selector) {
    IMP msgForwardIMP = _objc_msgForward;
#if !defined(__arm64__)
    // As an ugly internal runtime implementation detail in the 32bit runtime, we need to determine of the method we hook returns a struct or anything larger than id.
    // https://developer.apple.com/library/mac/documentation/DeveloperTools/Conceptual/LowLevelABI/000-Introduction/introduction.html
    // https://github.com/ReactiveCocoa/ReactiveCocoa/issues/783
    // http://infocenter.arm.com/help/topic/com.arm.doc.ihi0042e/IHI0042E_aapcs.pdf (Section 5.4)
    Method method = class_getInstanceMethod(self.class, selector);
    const char *encoding = method_getTypeEncoding(method);
    BOOL methodReturnsStructValue = encoding[0] == _C_STRUCT_B;
    if (methodReturnsStructValue) {
        @try {
            NSUInteger valueSize = 0;
            NSGetSizeAndAlignment(encoding, &valueSize, NULL);

            if (valueSize == 1 || valueSize == 2 || valueSize == 4 || valueSize == 8) {
                methodReturnsStructValue = NO;
            }
        } @catch (NSException *e) {}
    }
    if (methodReturnsStructValue) {
        msgForwardIMP = (IMP)_objc_msgForward_stret;
    }
#endif
    return msgForwardIMP;
}

static void aspect_prepareClassAndHookSelector(NSObject *self, SEL selector, NSError **error) {
    
    // 断言参数 selector 不能为空
    NSCParameterAssert(selector);
    
    // 如果是类 就hook函数forwardinvocation 返回类
    // 如果是实例 就修改原函数类 返回修改过的类
    Class klass = aspect_hookClass(self, error);
    
    // 创建Method对象
    Method targetMethod = class_getInstanceMethod(klass, selector);
    // 获取方法实现 IMP
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    
    
    // 如果这个实现不是消息转发 ForwardIMP
    if (!aspect_isMsgForwardIMP(targetMethodIMP)) {

        // Make a method alias for the existing method implementation, it not already copied.
        // 得到方法 TypeEncoding
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        // 获取方法别名
        SEL aliasSelector = aspect_aliasForSelector(selector);

        // 如果 不能响应 aspect 别名方法
        if (![klass instancesRespondToSelector:aliasSelector]) {

            // 给kclass添加别名方法 实现用原函数实现
            __unused BOOL addedAlias = class_addMethod(klass, aliasSelector, method_getImplementation(targetMethod), typeEncoding);
            NSCAssert(addedAlias, @"Original implementation for %@ is already copied to %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);
        }

        // We use forwardInvocation to hook in.
        // 替换klass的selector用_objc_msgForward替换
        // 将消息转发函数实现 替换 hook 原函数实现
        class_replaceMethod(klass, selector, aspect_getMsgForwardIMP(self, selector), typeEncoding);
        AspectLog(@"Aspects: Installed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }
}

// Will undo the runtime changes made.
static void aspect_cleanupHookedClassAndSelector(NSObject *self, SEL selector) {
    NSCParameterAssert(self);
    NSCParameterAssert(selector);

	Class klass = object_getClass(self);
    BOOL isMetaClass = class_isMetaClass(klass);
    if (isMetaClass) {
        klass = (Class)self;
    }

    // Check if the method is marked as forwarded and undo that.
    Method targetMethod = class_getInstanceMethod(klass, selector);
    IMP targetMethodIMP = method_getImplementation(targetMethod);
    if (aspect_isMsgForwardIMP(targetMethodIMP)) {
        // Restore the original method implementation.
        const char *typeEncoding = method_getTypeEncoding(targetMethod);
        SEL aliasSelector = aspect_aliasForSelector(selector);
        Method originalMethod = class_getInstanceMethod(klass, aliasSelector);
        IMP originalIMP = method_getImplementation(originalMethod);
        NSCAssert(originalMethod, @"Original implementation for %@ not found %@ on %@", NSStringFromSelector(selector), NSStringFromSelector(aliasSelector), klass);

        class_replaceMethod(klass, selector, originalIMP, typeEncoding);
        AspectLog(@"Aspects: Removed hook for -[%@ %@].", klass, NSStringFromSelector(selector));
    }

    // Deregister global tracked selector
    aspect_deregisterTrackedSelector(self, selector);

    // Get the aspect container and check if there are any hooks remaining. Clean up if there are not.
    AspectsContainer *container = aspect_getContainerForObject(self, selector);
    if (!container.hasAspects) {
        // Destroy the container
        aspect_destroyContainerForObject(self, selector);

        // Figure out how the class was modified to undo the changes.
        NSString *className = NSStringFromClass(klass);
        if ([className hasSuffix:AspectsSubclassSuffix]) {
            Class originalClass = NSClassFromString([className stringByReplacingOccurrencesOfString:AspectsSubclassSuffix withString:@""]);
            NSCAssert(originalClass != nil, @"Original class must exist");
            object_setClass(self, originalClass);
            AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(originalClass));

            // We can only dispose the class pair if we can ensure that no instances exist using our subclass.
            // Since we don't globally track this, we can't ensure this - but there's also not much overhead in keeping it around.
            //objc_disposeClassPair(object.class);
        }else {
            // Class is most likely swizzled in place. Undo that.
            if (isMetaClass) {
                aspect_undoSwizzleClassInPlace((Class)self);
            }
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Hook Class

static Class aspect_hookClass(NSObject *self, NSError **error) {
    
    // 断言参数 self 不能为空
    NSCParameterAssert(self);
    
    // 得到 Class 对象
	Class statedClass = self.class;
    // 得到 元类(metaclass)，这里不严谨 如果是实例取调用的话，得到的是类，不是元类。
    // object_getClass得到isa指针指向的对象
	Class baseClass = object_getClass(self);
    
    // 拿到class的字符串
	NSString *className = NSStringFromClass(baseClass);

    // Already subclassed
    // 是否有 _Aspects_ 结尾标识
	if ([className hasSuffix:AspectsSubclassSuffix]) {
		return baseClass;

        // We swizzle a class object, not a single object.
	}else if (class_isMetaClass(baseClass)) { // baseClass 是不是 元类
        // hook "forward invocation" 函数
        return aspect_swizzleClassInPlace((Class)self);
        // Probably a KVO'ed class. Swizzle in place. Also swizzle meta classes in place.
    }else if (statedClass != baseClass) {
        // hook "forward invocation" 函数
        return aspect_swizzleClassInPlace(baseClass);
    }

    
    // Default case. Create dynamic subclass.
    // 动态生成 AspectsSubclassSuffix 结尾的 类名
	const char *subclassName = [className stringByAppendingString:AspectsSubclassSuffix].UTF8String;
    // 获取其 subclassName isa 指针指向的对象
	Class subclass = objc_getClass(subclassName);

    // 不存在这个 subclass
	if (subclass == nil) {
        
        // 动态alloc类
		subclass = objc_allocateClassPair(baseClass, subclassName, 0);
        
		if (subclass == nil) {
            // alloc分配失败
            NSString *errrorDesc = [NSString stringWithFormat:@"objc_allocateClassPair failed to allocate class %s.", subclassName];
            AspectError(AspectErrorFailedToAllocateClassPair, errrorDesc);
            return nil;
        }

        // Hook ForwardInvocation
		aspect_swizzleForwardInvocation(subclass);
        
		aspect_hookedGetClass(subclass, statedClass);
		aspect_hookedGetClass(object_getClass(subclass), statedClass);
        
		objc_registerClassPair(subclass);
	}

    // 设置self的类是 subclass (例如 ViewController_Aspects_ 带_Aspects_后缀的)
	object_setClass(self, subclass);
    NSLog(@"self class:%@",self.class);
	return subclass;
}

static NSString *const AspectsForwardInvocationSelectorName = @"__aspects_forwardInvocation:";
static void aspect_swizzleForwardInvocation(Class klass) {
    
    // 断言参数kclass不为空
    NSCParameterAssert(klass);
    
    // If there is no method, replace will act like class_addMethod.
    // 用aspect的__ASPECTS_ARE_BEING_CALLED__方法实现取替换 “forwardInvocation:” 方法，并且返回原实现 IMP
    IMP originalImplementation = class_replaceMethod(klass, @selector(forwardInvocation:), (IMP)__ASPECTS_ARE_BEING_CALLED__, "v@:@");
    if (originalImplementation) { // 如果替换成功了
        // 为这个类再添加一个 名字叫 __aspects_forwardInvocation: 的方法，实现用 originalImplementation。
        class_addMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName), originalImplementation, "v@:@");
    }
    
    AspectLog(@"Aspects: %@ is now aspect aware.", NSStringFromClass(klass));
}

static void aspect_undoSwizzleForwardInvocation(Class klass) {
    NSCParameterAssert(klass);
    Method originalMethod = class_getInstanceMethod(klass, NSSelectorFromString(AspectsForwardInvocationSelectorName));
    Method objectMethod = class_getInstanceMethod(NSObject.class, @selector(forwardInvocation:));
    // There is no class_removeMethod, so the best we can do is to retore the original implementation, or use a dummy.
    IMP originalImplementation = method_getImplementation(originalMethod ?: objectMethod);
    class_replaceMethod(klass, @selector(forwardInvocation:), originalImplementation, "v@:@");

    AspectLog(@"Aspects: %@ has been restored.", NSStringFromClass(klass));
}

static void aspect_hookedGetClass(Class class, Class statedClass) {
    
    // 参数 statedClass class 不为空
    NSCParameterAssert(class);
    NSCParameterAssert(statedClass);
    
	Method method = class_getInstanceMethod(class, @selector(class));
    NSLog(@"class:%@",class);
	IMP newIMP = imp_implementationWithBlock(^(id self) {
		return statedClass;
	});
	class_replaceMethod(class, @selector(class), newIMP, method_getTypeEncoding(method));
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Swizzle Class In Place

static void _aspect_modifySwizzledClasses(void (^block)(NSMutableSet *swizzledClasses)) {
    static NSMutableSet *swizzledClasses;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClasses = [NSMutableSet new];
    });
    @synchronized(swizzledClasses) {
        block(swizzledClasses);
    }
}

static Class aspect_swizzleClassInPlace(Class klass) {
    
    // 断言参数 kclass 不为空
    NSCParameterAssert(klass);
    
    // 得到类名 NSString
    NSString *className = NSStringFromClass(klass);

    // block执行使用@synchronized来进行保证线程安全
    // 返回全局静态 swizzledClasses 集合。
    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        
        // 如果 swizzledClasses 集合不包含 className
        if (![swizzledClasses containsObject:className]) {
            
            // 交换 ForwardInvocation 方法
            aspect_swizzleForwardInvocation(klass);
            
            // 添加className到swizzledClasses
            [swizzledClasses addObject:className];
        }
    });
    return klass;
}

static void aspect_undoSwizzleClassInPlace(Class klass) {
    NSCParameterAssert(klass);
    NSString *className = NSStringFromClass(klass);

    _aspect_modifySwizzledClasses(^(NSMutableSet *swizzledClasses) {
        if ([swizzledClasses containsObject:className]) {
            aspect_undoSwizzleForwardInvocation(klass);
            [swizzledClasses removeObject:className];
        }
    });
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Invoke Point

// This is a macro so we get a cleaner stack trace.
#define aspect_invoke(aspects, info) \
for (AspectIdentifier *aspect in aspects) {\
    [aspect invokeWithInfo:info];\
    if (aspect.options & AspectOptionAutomaticRemoval) { \
        aspectsToRemove = [aspectsToRemove?:@[] arrayByAddingObject:aspect]; \
    } \
}

// This is the swizzled forwardInvocation: method.
static void __ASPECTS_ARE_BEING_CALLED__(__unsafe_unretained NSObject *self, SEL selector, NSInvocation *invocation) {
    
    // 注: 这里是aspect hook的 forward 方法的实现
    
    // 断言参数 self invocation 不为空
    NSCParameterAssert(self);
    NSCParameterAssert(invocation);
    
    // 获取 invocation 的SEL方法名
    SEL originalSelector = invocation.selector;
    // 拼接 别名方法 通过 SEL
	SEL aliasSelector = aspect_aliasForSelector(invocation.selector);
    
    // 替换invocation中的调用方法
    invocation.selector = aliasSelector;
    
    // 通过aspect别名方法获取关联对象 AspectsContainer
    AspectsContainer *objectContainer = objc_getAssociatedObject(self, aliasSelector);
    
    // 通过aspect别名方法获取关联对象 AspectsContainer
    // object_getClass(self) 是 self的isa指向的位置，如果 self 是实例 就指向 类，如果 self 是类 就指向 元类。
    AspectsContainer *classContainer = aspect_getContainerForClass(object_getClass(self), aliasSelector);
    
    // 创建 AspectInfo 对象通过 self 和 invocation
    AspectInfo *info = [[AspectInfo alloc] initWithInstance:self invocation:invocation];
    
    // 创建 aspectsToRemove变量 待用
    NSArray *aspectsToRemove = nil;

    
    
    // Before hooks.
    aspect_invoke(classContainer.beforeAspects, info);
    aspect_invoke(objectContainer.beforeAspects, info);

    
    
    // Instead hooks.
    BOOL respondsToAlias = YES;
    if (objectContainer.insteadAspects.count || classContainer.insteadAspects.count) {
        aspect_invoke(classContainer.insteadAspects, info);
        aspect_invoke(objectContainer.insteadAspects, info);
    }else {
        
        // 获取invoke对象
        Class klass = object_getClass(invocation.target);
        
        // 如果可以响应 别名函数，循环调用。
        // 这里invoke是调用的原函数
        do {
            if ((respondsToAlias = [klass instancesRespondToSelector:aliasSelector])) {
                [invocation invoke];
                break;
            }
        }while (!respondsToAlias && (klass = class_getSuperclass(klass)));
    }

    
    
    // After hooks.
    aspect_invoke(classContainer.afterAspects, info);
    aspect_invoke(objectContainer.afterAspects, info);

    
    
    // If no hooks are installed, call original implementation (usually to throw an exception)
    // 如果不响应别名函数
    if (!respondsToAlias) {
        
        invocation.selector = originalSelector;
        SEL originalForwardInvocationSEL = NSSelectorFromString(AspectsForwardInvocationSelectorName);
        if ([self respondsToSelector:originalForwardInvocationSEL]) { // 可以响应原函数
            // 用 objc_msgSend 给自己发送 originalForwardInvocationSEL 消息携带参数 invocation
            ((void( *)(id, SEL, NSInvocation *))objc_msgSend)(self, originalForwardInvocationSEL, invocation);
        }else {
            // 无法响应原函数，调用不识别方法。
            [self doesNotRecognizeSelector:invocation.selector];
        }
    }

    // Remove any hooks that are queued for deregistration.
    [aspectsToRemove makeObjectsPerformSelector:@selector(remove)];
}
#undef aspect_invoke

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Aspect Container Management

// Loads or creates the aspect container.
// objc_setAssociatedObject 用于给对象添加关联对象，传入 nil 则可以移除已有的关联对象；
// objc_getAssociatedObject 用于获取关联对象；
// objc_removeAssociatedObjects 用于移除一个对象的所有关联对象。
static AspectsContainer *aspect_getContainerForObject(NSObject *self, SEL selector) {
    
    // 断言参数不为空
    NSCParameterAssert(self);
    
    // 创建别名hook函数 "aspects__viewWillAppear:"
    SEL aliasSelector = aspect_aliasForSelector(selector);
    
    // 通过 hook函数别名 去获取 AspectsContainer
    AspectsContainer *aspectContainer = objc_getAssociatedObject(self, aliasSelector);
    
    // 如果没有获取到 aspectContainer，创建一个新的，并且为self添加关联对象，key aliasSelector，value aspectContainer
    if (!aspectContainer) {
        aspectContainer = [AspectsContainer new];
        objc_setAssociatedObject(self, aliasSelector, aspectContainer, OBJC_ASSOCIATION_RETAIN);
    }
    
    return aspectContainer;
}

static AspectsContainer *aspect_getContainerForClass(Class klass, SEL selector) {
    
    // 断言 klass 参数不为空
    NSCParameterAssert(klass);
    // 创建容器变量 classContainer 待用
    AspectsContainer *classContainer = nil;
    
    // 遍历整个class层级，如果哪一个classContainer存在identifier就直接跳出循环直接返回这个容器。
    do {
        classContainer = objc_getAssociatedObject(klass, selector);
        if (classContainer.hasAspects) break;
    }while ((klass = class_getSuperclass(klass)));

    return classContainer;
}

static void aspect_destroyContainerForObject(id<NSObject> self, SEL selector) {
    NSCParameterAssert(self);
    SEL aliasSelector = aspect_aliasForSelector(selector);
    objc_setAssociatedObject(self, aliasSelector, nil, OBJC_ASSOCIATION_RETAIN);
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Selector Blacklist Checking

static NSMutableDictionary *aspect_getSwizzledClassesDict() {
    static NSMutableDictionary *swizzledClassesDict;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        swizzledClassesDict = [NSMutableDictionary new];
    });
    return swizzledClassesDict;
}

static BOOL aspect_isSelectorAllowedAndTrack(NSObject *self, SEL selector, AspectOptions options, NSError **error) {
    
    // 不允许跟踪的方法列表集合 黑名单
    static NSSet *disallowedSelectorList;
    
    // 只执行一次token这个很简单了，OC实现Singleton我们都会用到。
    static dispatch_once_t pred;
    
    // 设置黑名单 retain release autorelease forwardInvocation， 可以看出这些都是系统方法。
    dispatch_once(&pred, ^{
        disallowedSelectorList = [NSSet setWithObjects:@"retain", @"release", @"autorelease", @"forwardInvocation:", nil];
    });

    
    // Check against the blacklist.
    // 检查一遍参数 selector 是不是在黑名单里面，如果在黑名单里面直接返回，并且通过AspectError打印 Error Log
    NSString *selectorName = NSStringFromSelector(selector);
    if ([disallowedSelectorList containsObject:selectorName]) {
        NSString *errorDescription = [NSString stringWithFormat:@"Selector %@ is blacklisted.", selectorName];
        AspectError(AspectErrorSelectorBlacklisted, errorDescription);
        return NO;
    }
    
    
    // Additional checks.
    // Hook 系统Dealloc函数，只有AspectPositionBefore有效，其他方式无意义，直接返回，并且打印Error。
    // 想想也是 dealloc 肯定是在 系统dealloc 执行之前 执行hook的dealloc 才有意义。
    AspectOptions position = options&AspectPositionFilter;
    if ([selectorName isEqualToString:@"dealloc"] && position != AspectPositionBefore) {
        NSString *errorDesc = @"AspectPositionBefore is the only valid position when hooking dealloc.";
        AspectError(AspectErrorSelectorDeallocPosition, errorDesc);
        return NO;
    }

    // 确保传入的selector确实可以被响应
    if (![self respondsToSelector:selector] && ![self.class instancesRespondToSelector:selector]) {
        NSString *errorDesc = [NSString stringWithFormat:@"Unable to find selector -[%@ %@].", NSStringFromClass(self.class), selectorName];
        AspectError(AspectErrorDoesNotRespondToSelector, errorDesc);
        return NO;
    }

    // Search for the current class and the class hierarchy IF we are modifying a class object
    // 这里 object_getClass(self) 是获取元类
    // object_getClass(instance) 指向--> class
    // object_getClass(class) 指向--> metaclass 元类
    // 如果有metaclass元类，self必须是class，不能是instance，因为只有class的isa才指向metaclass
    if (class_isMetaClass(object_getClass(self))) {
        
        // 获取 Class(objc_class) 类型
        // 这里解释一下，下面的变量 currentClass 会在下面的逻辑中更改，在更改完成后，需要将 klass 赋值给 currentClass。
        // 所以这里创建了 两个一摸一样的变量 klass currentClass。
        Class klass = [self class];
        // 生成唯一静态 swizzledClassesDict 维护字典。
        NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
        // 获取 Class(objc_class) 类型
        Class currentClass = [self class];
        
        do {
            
            // 如果currentClass已经之前已经有添加在 swizzledClassesDict 中，就取出那个 tracker。
            AspectTracker *tracker = swizzledClassesDict[currentClass];
            // 如果tracker还包含这个需要hook的方法
            if ([tracker.selectorNames containsObject:selectorName]) {

                // Find the topmost class for the log.
                // 如果存在parentEntry，就提示无法再hook了。
                // 解释一下: 比如A类继承C类，B类继承C类，但是B类已经之前hook了一个叫aaa的方法了，A类就不能再hook这个叫aaa方法名的方法了。
                if (tracker.parentEntry) {
                    
                    // 找到整个链最上层的tracker赋给topmostEntry
                    AspectTracker *topmostEntry = tracker.parentEntry;
                    while (topmostEntry.parentEntry) {
                        topmostEntry = topmostEntry.parentEntry;
                    }
                    
                    // 打印信息：之前已经hook过了，只能hook一次，在这个class的层级。
                    NSString *errorDescription = [NSString stringWithFormat:@"Error: %@ already hooked in %@. A method can only be hooked once per class hierarchy.", selectorName, NSStringFromClass(topmostEntry.trackedClass)];
                    AspectError(AspectErrorSelectorAlreadyHookedInClassHierarchy, errorDescription);
                    return NO;
                }else if (klass == currentClass) {
                    // Already modified and topmost!
                    // 再解释一下，走到这里意味着，比如之前A类已经hook了aaa方法了，但是现在你又在它下面又hook一遍aaa方法。
                    // 所以直接方法YES，也就是允许你替换之前hook的实现。
                    return YES;
                }
            }
        
        // while(currentClass = class_getSuperclass(currentClass)) 当currentClass最终等于nil就结束这个while
        // 已ViewController为例子，一下是每次循环的结果
        // class_getSuperclass(currentClass) = UIViewController
        // class_getSuperclass(currentClass) = UIResponder
        // class_getSuperclass(currentClass) = NSObject
        // class_getSuperclass(currentClass) = nil
        // 可以看出，当我们寻找 class_getSuperclass(NSObject.class) 的时候，就此再无父类了。
        }while ((currentClass = class_getSuperclass(currentClass)));

        
        
        // Add the selector as being modified.
        // 因为 currentClass 在上面do while中被修改 (while ((currentClass = class_getSuperclass(currentClass))))
        // 所以将之前声明的 currentClass 只不过命名为 klass 的变量 再度给 currentClass 变量赋值。
        currentClass = klass;
        // 创建 parentTracker 变量待命
        AspectTracker *parentTracker = nil;
        
        do {
            
            // 如果之前这个currentClass有使用aspect，那么肯定会在这个 swizzledClassesDict 字典中，然后取出 AspectTracker
            // 如果之前没有，这时第一次，取到 nil
            AspectTracker *tracker = swizzledClassesDict[currentClass];
            
            // 如果没取到tracker，这个类第一次使用aspect
            // 创建AspectTracker，并且给 swizzledClassesDict 添加value为 tracker，key为currentClass
            if (!tracker) {
                
                // 这里有意思的是 parentTracker 这个变量
                // 比如我们已ViewController类为例
                // Tracker初始化第一次: ViewController ，parent nil
                // Tracker初始化第二次: UIViewController， parent ViewController
                // Tracker初始化第三次: ViewController， parent UIRespond
                // Tracker初始化第四次: NSObject， parent UIRespond
                // 如果我在子类添加一个方法的hook，aspect会生成一个从子类到父类的链路tracker，为每个tracker都添加要hook的方法
                tracker = [[AspectTracker alloc] initWithTrackedClass:currentClass parent:parentTracker];
                swizzledClassesDict[(id<NSCopying>)currentClass] = tracker;
            }
            
            // 给这个刚创建的tracker添加需要hook的方法名字，加入到tracker的方法数组里面 selectorNames
            [tracker.selectorNames addObject:selectorName];
            
            // All superclasses get marked as having a subclass that is modified.
            parentTracker = tracker;
        }while ((currentClass = class_getSuperclass(currentClass)));
        
    }

    return YES;
}

static void aspect_deregisterTrackedSelector(id self, SEL selector) {
    if (!class_isMetaClass(object_getClass(self))) return;

    NSMutableDictionary *swizzledClassesDict = aspect_getSwizzledClassesDict();
    NSString *selectorName = NSStringFromSelector(selector);
    Class currentClass = [self class];
    do {
        AspectTracker *tracker = swizzledClassesDict[currentClass];
        if (tracker) {
            [tracker.selectorNames removeObject:selectorName];
            if (tracker.selectorNames.count == 0) {
                [swizzledClassesDict removeObjectForKey:tracker];
            }
        }
    }while ((currentClass = class_getSuperclass(currentClass)));
}

@end

@implementation AspectTracker

- (id)initWithTrackedClass:(Class)trackedClass parent:(AspectTracker *)parent {
    if (self = [super init]) {
        _trackedClass = trackedClass;
        _parentEntry = parent;
        _selectorNames = [NSMutableSet new];
    }
    return self;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %@, trackedClass: %@, selectorNames:%@, parent:%p>", self.class, self, NSStringFromClass(self.trackedClass), self.selectorNames, self.parentEntry];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSInvocation (Aspects)

@implementation NSInvocation (Aspects)

// Thanks to the ReactiveCocoa team for providing a generic solution for this.
- (id)aspect_argumentAtIndex:(NSUInteger)index {
	const char *argType = [self.methodSignature getArgumentTypeAtIndex:index];
	// Skip const type qualifier.
	if (argType[0] == _C_CONST) argType++;

#define WRAP_AND_RETURN(type) do { type val = 0; [self getArgument:&val atIndex:(NSInteger)index]; return @(val); } while (0)
	if (strcmp(argType, @encode(id)) == 0 || strcmp(argType, @encode(Class)) == 0) {
		__autoreleasing id returnObj;
		[self getArgument:&returnObj atIndex:(NSInteger)index];
		return returnObj;
	} else if (strcmp(argType, @encode(SEL)) == 0) {
        SEL selector = 0;
        [self getArgument:&selector atIndex:(NSInteger)index];
        return NSStringFromSelector(selector);
    } else if (strcmp(argType, @encode(Class)) == 0) {
        __autoreleasing Class theClass = Nil;
        [self getArgument:&theClass atIndex:(NSInteger)index];
        return theClass;
        // Using this list will box the number with the appropriate constructor, instead of the generic NSValue.
	} else if (strcmp(argType, @encode(char)) == 0) {
		WRAP_AND_RETURN(char);
	} else if (strcmp(argType, @encode(int)) == 0) {
		WRAP_AND_RETURN(int);
	} else if (strcmp(argType, @encode(short)) == 0) {
		WRAP_AND_RETURN(short);
	} else if (strcmp(argType, @encode(long)) == 0) {
		WRAP_AND_RETURN(long);
	} else if (strcmp(argType, @encode(long long)) == 0) {
		WRAP_AND_RETURN(long long);
	} else if (strcmp(argType, @encode(unsigned char)) == 0) {
		WRAP_AND_RETURN(unsigned char);
	} else if (strcmp(argType, @encode(unsigned int)) == 0) {
		WRAP_AND_RETURN(unsigned int);
	} else if (strcmp(argType, @encode(unsigned short)) == 0) {
		WRAP_AND_RETURN(unsigned short);
	} else if (strcmp(argType, @encode(unsigned long)) == 0) {
		WRAP_AND_RETURN(unsigned long);
	} else if (strcmp(argType, @encode(unsigned long long)) == 0) {
		WRAP_AND_RETURN(unsigned long long);
	} else if (strcmp(argType, @encode(float)) == 0) {
		WRAP_AND_RETURN(float);
	} else if (strcmp(argType, @encode(double)) == 0) {
		WRAP_AND_RETURN(double);
	} else if (strcmp(argType, @encode(BOOL)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(bool)) == 0) {
		WRAP_AND_RETURN(BOOL);
	} else if (strcmp(argType, @encode(char *)) == 0) {
		WRAP_AND_RETURN(const char *);
	} else if (strcmp(argType, @encode(void (^)(void))) == 0) {
		__unsafe_unretained id block = nil;
		[self getArgument:&block atIndex:(NSInteger)index];
		return [block copy];
	} else {
		NSUInteger valueSize = 0;
		NSGetSizeAndAlignment(argType, &valueSize, NULL);

		unsigned char valueBytes[valueSize];
		[self getArgument:valueBytes atIndex:(NSInteger)index];

		return [NSValue valueWithBytes:valueBytes objCType:argType];
	}
	return nil;
#undef WRAP_AND_RETURN
}

- (NSArray *)aspects_arguments {
	NSMutableArray *argumentsArray = [NSMutableArray array];
	for (NSUInteger idx = 2; idx < self.methodSignature.numberOfArguments; idx++) {
		[argumentsArray addObject:[self aspect_argumentAtIndex:idx] ?: NSNull.null];
	}
	return [argumentsArray copy];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectIdentifier

@implementation AspectIdentifier

+ (instancetype)identifierWithSelector:(SEL)selector object:(id)object options:(AspectOptions)options block:(id)block error:(NSError **)error {
    
    // 断言参数 block  selector 不能为空
    NSCParameterAssert(block);
    NSCParameterAssert(selector);
    
    // 获取匿名函数Block的方法签名
    NSMethodSignature *blockSignature = aspect_blockMethodSignature(block, error); // TODO: check signature compatibility, etc.
    
    // 字面意思，不兼容block方法签名 直接返回nil
    // 实际是看 hook的block 和 原方法，方法签名中 参数和返回值类型属否一致，如果不一致就提示方法签名不匹配。
    if (!aspect_isCompatibleBlockSignature(blockSignature, object, selector, error)) {
        return nil;
    }

    // 创建 AspectIdentifier 变量待用
    AspectIdentifier *identifier = nil;
    if (blockSignature) { // 如果block方法签名存在
        identifier = [AspectIdentifier new]; // 创建实例
        identifier.selector = selector; // 方法赋值
        identifier.block = block; // block赋值
        identifier.blockSignature = blockSignature; // block方法签名赋值
        identifier.options = options; // aspect的hook策略参数赋值
        identifier.object = object; // weak 被hook对象 赋给identifier.object
    }
    return identifier;
}

- (BOOL)invokeWithInfo:(id<AspectInfo>)info {
    NSInvocation *blockInvocation = [NSInvocation invocationWithMethodSignature:self.blockSignature];
    NSInvocation *originalInvocation = info.originalInvocation;
    NSUInteger numberOfArguments = self.blockSignature.numberOfArguments;

    // Be extra paranoid. We already check that on hook registration.
    if (numberOfArguments > originalInvocation.methodSignature.numberOfArguments) {
        AspectLogError(@"Block has too many arguments. Not calling %@", info);
        return NO;
    }

    // The `self` of the block will be the AspectInfo. Optional.
    if (numberOfArguments > 1) {
        [blockInvocation setArgument:&info atIndex:1];
    }
    
	void *argBuf = NULL;
    for (NSUInteger idx = 2; idx < numberOfArguments; idx++) {
        const char *type = [originalInvocation.methodSignature getArgumentTypeAtIndex:idx];
		NSUInteger argSize;
		NSGetSizeAndAlignment(type, &argSize, NULL);
        
		if (!(argBuf = reallocf(argBuf, argSize))) {
            AspectLogError(@"Failed to allocate memory for block invocation.");
			return NO;
		}
        
		[originalInvocation getArgument:argBuf atIndex:idx];
		[blockInvocation setArgument:argBuf atIndex:idx];
    }
    
    [blockInvocation invokeWithTarget:self.block];
    
    if (argBuf != NULL) {
        free(argBuf);
    }
    return YES;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, SEL:%@ object:%@ options:%tu block:%@ (#%tu args)>", self.class, self, NSStringFromSelector(self.selector), self.object, self.options, self.block, self.blockSignature.numberOfArguments];
}

- (BOOL)remove {
    return aspect_remove(self, NULL);
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectsContainer

@implementation AspectsContainer

- (BOOL)hasAspects {
    return self.beforeAspects.count > 0 || self.insteadAspects.count > 0 || self.afterAspects.count > 0;
}

- (void)addAspect:(AspectIdentifier *)aspect withOptions:(AspectOptions)options {
    NSParameterAssert(aspect);
    NSUInteger position = options&AspectPositionFilter;
    switch (position) {
        case AspectPositionBefore:  self.beforeAspects  = [(self.beforeAspects ?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionInstead: self.insteadAspects = [(self.insteadAspects?:@[]) arrayByAddingObject:aspect]; break;
        case AspectPositionAfter:   self.afterAspects   = [(self.afterAspects  ?:@[]) arrayByAddingObject:aspect]; break;
    }
}

- (BOOL)removeAspect:(id)aspect {
    for (NSString *aspectArrayName in @[NSStringFromSelector(@selector(beforeAspects)),
                                        NSStringFromSelector(@selector(insteadAspects)),
                                        NSStringFromSelector(@selector(afterAspects))]) {
        NSArray *array = [self valueForKey:aspectArrayName];
        NSUInteger index = [array indexOfObjectIdenticalTo:aspect];
        if (array && index != NSNotFound) {
            NSMutableArray *newArray = [NSMutableArray arrayWithArray:array];
            [newArray removeObjectAtIndex:index];
            [self setValue:newArray forKey:aspectArrayName];
            return YES;
        }
    }
    return NO;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p, before:%@, instead:%@, after:%@>", self.class, self, self.beforeAspects, self.insteadAspects, self.afterAspects];
}

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - AspectInfo

@implementation AspectInfo

@synthesize arguments = _arguments;

- (id)initWithInstance:(__unsafe_unretained id)instance invocation:(NSInvocation *)invocation {
    NSCParameterAssert(instance);
    NSCParameterAssert(invocation);
    if (self = [super init]) {
        _instance = instance;
        _originalInvocation = invocation;
    }
    return self;
}

- (NSArray *)arguments {
    // Lazily evaluate arguments, boxing is expensive.
    if (!_arguments) {
        _arguments = self.originalInvocation.aspects_arguments;
    }
    return _arguments;
}

@end
