(*
    Copyright (c) 2016-19 David C.J. Matthews

    This library is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License version 2.1 as published by the Free Software Foundation.
    
    This library is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
    Lesser General Public License for more details.
    
    You should have received a copy of the GNU Lesser General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
*)

functor X86FOREIGNCALL(

    structure X86CODE: X86CODESIG

    structure X86OPTIMISE:
    sig
        type operation
        type code
        type operations = operation list
        type closureRef

        (* Optimise and code-generate. *)
        val generateCode: {code: code, ops: operations, labelCount: int, resultClosure: closureRef} -> unit

        structure Sharing:
        sig
            type operation = operation
            type code = code
            type closureRef = closureRef
        end
    end

    structure DEBUG: DEBUGSIG
    
    structure CODE_ARRAY: CODEARRAYSIG

    sharing X86CODE.Sharing = X86OPTIMISE.Sharing = CODE_ARRAY.Sharing
): FOREIGNCALLSIG
=
struct
    open X86CODE
    open Address
    open CODE_ARRAY
    
    val memRegSize = 0
   
    val (polyWordOpSize, nativeWordOpSize) =
        case targetArch of
            Native32Bit     => (OpSize32, OpSize32)
        |   Native64Bit     => (OpSize64, OpSize64)
        |   ObjectId32Bit   => (OpSize32, OpSize64)
    
    (* Ebx/Rbx is used for the second argument on the native architectures but
       is replaced by esi on the object ID arch because ebx is used as the
       global base register. *)
    val mlArg2Reg = case targetArch of ObjectId32Bit => esi | _ => ebx
    
    exception InternalError = Misc.InternalError
  
    fun opSizeToMove OpSize32 = Move32 | opSizeToMove OpSize64 = Move64

    val pushR = PushToStack o RegisterArg

    fun moveRR{source, output, opSize} =
        Move{source=RegisterArg source, destination=RegisterArg output, moveSize=opSizeToMove opSize}

    fun loadMemory(reg, base, offset, opSize) =
        Move{source=MemoryArg{base=base, offset=offset, index=NoIndex}, destination=RegisterArg reg, moveSize=opSizeToMove opSize}
    and storeMemory(reg, base, offset, opSize) =
        Move{source=RegisterArg reg, destination=MemoryArg {base=base, offset=offset, index=NoIndex}, moveSize=opSizeToMove opSize}
    
    val loadHeapMemory =
        case targetArch of
            ObjectId32Bit =>
                (
                    fn (reg, base, offset, opSize) => 
                        Move{source=MemoryArg{base=ebx, offset=offset, index=Index4 base},
                             destination=RegisterArg reg, moveSize=opSizeToMove opSize}
                )
        |   _ => loadMemory

    fun createProfileObject _ (*functionName*) =
    let
        (* The profile object is a single mutable with the F_bytes bit set. *)
        open Address
        val profileObject = RunCall.allocateByteMemory(0w1, Word.fromLargeWord(Word8.toLargeWord(Word8.orb(F_mutable, F_bytes))))
        fun clear 0w0 = ()
        |   clear i = (assignByte(profileObject, i-0w1, 0w0); clear (i-0w1))
        val () = clear wordSize
    in
        toMachineWord profileObject
    end

    val makeEntryPoint: string -> machineWord = RunCall.rtsCallFull1 "PolyCreateEntryPointObject"

    datatype abi = X86_32 | X64Win | X64Unix
    
    local
        (* Get the ABI.  On 64-bit Windows and Unix use different calling conventions. *)
        val getABICall: unit -> int = RunCall.rtsCallFast0 "PolyGetABI"
    in
        fun getABI() =
            case getABICall() of
                0 => X86_32
            |   1 => X64Unix
            |   2 => X64Win
            |   n => raise InternalError ("Unknown ABI type " ^ Int.toString n)
    end

    val noException = 1

    (* Full RTS call version.  An extra argument is passed that contains the thread ID.
       This allows the taskData object to be found which is needed if the code allocates
       any ML memory or raises an exception.  It also saves the stack and heap pointers
       in case of a GC. *)
    fun rtsCallFull (functionName, nArgs (* Not counting the thread ID *), debugSwitches) =
    let
        val entryPointAddr = makeEntryPoint functionName

        (* Get the ABI.  On 64-bit Windows and Unix use different calling conventions. *)
        val abi = getABI()

        (* Branch to check for exception. *)
        val exLabel = Label{labelNo=0} (* There's just one label in this function. *)
        
        (* Unix X64.  The first six arguments are in rdi, rsi, rdx, rcx, r8, r9.
                      The rest are on the stack.
           Windows X64. The first four arguments are in rcx, rdx, r8 and r9.  The rest are
                       on the stack.  The caller must ensure the stack is aligned on 16-byte boundary
                       and must allocate 32-byte save area for the register args.
                       rbx, rbp, rdi, rsi, rsp, r12-r15 are saved by the called function.
           X86/32.  Arguments are pushed to the stack.
                   ebx, edi, esi, ebp and esp are saved by the called function.
                   We use esi to hold the argument data pointer and edi to save the ML stack pointer
           Our ML conventions use eax, ebx for the first two arguments in X86/32,
                   rax, ebx, r8, r9, r10 for the first five arguments in X86/64 and
                   rax, rsi, r8, r9 and r10 for the first five arguments in X86/64-32 bit.
        *)
        
        (* Previously the ML stack pointer was saved in a callee-save register.  This works
           in almost all circumstances except when a call to the FFI code results in a callback
           and the callback moves the ML stack.  Instead the RTS callback handler adjusts the value
           in memRegStackPtr and we reload the ML stack pointer from there. *)
        val entryPtrReg = if targetArch <> Native32Bit then r11 else ecx
        
        val stackSpace =
            case abi of
                X64Unix => memRegSize
            |   X64Win => memRegSize + 32 (* Requires 32-byte save area. *)
            |   X86_32 =>
                let
                    (* GCC likes to keep the stack on a 16-byte alignment. *)
                    val argSpace = (nArgs+1)*4
                    val align = argSpace mod 16
                in
                    (* Add sufficient space so that esp will be 16-byte aligned *)
                    if align = 0
                    then memRegSize
                    else memRegSize + 16 - align
                end

        (* The RTS functions expect the real address of the thread Id. *)
        fun loadThreadId toReg =
            if targetArch <> ObjectId32Bit
            then [loadMemory(toReg, ebp, memRegThreadSelf, nativeWordOpSize)]
            else [loadMemory(toReg, ebp, memRegThreadSelf, polyWordOpSize),
                  LoadAddress{output=toReg, offset=0, base=SOME ebx, index=Index4 toReg, opSize=nativeWordOpSize}]

        val code =
            [
                Move{source=AddressConstArg entryPointAddr, destination=RegisterArg entryPtrReg, moveSize=opSizeToMove polyWordOpSize}, (* Load the entry point ref. *)
                loadHeapMemory(entryPtrReg, entryPtrReg, 0, nativeWordOpSize)(* Load its value. *)
            ] @
            (
                (* Save heap ptr.  This is in r15 in X86/64 *)
                if targetArch <> Native32Bit then [storeMemory(r15, ebp, memRegLocalMPointer, nativeWordOpSize)] (* Save heap ptr *)
                else []
            ) @
            (
                if abi = X86_32 andalso nArgs >= 3
                then [moveRR{source=esp, output=edi, opSize=nativeWordOpSize}] (* Needed if we have to load from the stack. *)
                else []
            ) @
            
            [
                (* Have to save the stack pointer to the arg structure in case we need to scan the stack for a GC. *)
                storeMemory(esp, ebp, memRegStackPtr, nativeWordOpSize), (* Save ML stack and switch to C stack. *)
                loadMemory(esp, ebp, memRegCStackPtr, nativeWordOpSize), (*moveRR{source=ebp, output=esp},*) (* Load the saved C stack pointer. *)
                (* Set the stack pointer past the data on the stack.  For Windows/64 add in a 32 byte save area *)
                ArithToGenReg{opc=SUB, output=esp, source=NonAddressConstArg(LargeInt.fromInt stackSpace), opSize=nativeWordOpSize}
            ] @
            (
                case (abi, nArgs) of  (* Set the argument registers. *)
                    (X64Unix, 0) => loadThreadId edi
                |   (X64Unix, 1) => moveRR{source=eax, output=esi, opSize=polyWordOpSize} :: loadThreadId edi
                |   (X64Unix, 2) =>
                        moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize} ::
                        moveRR{source=eax, output=esi, opSize=polyWordOpSize} :: loadThreadId edi
                |   (X64Unix, 3) => 
                        moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize} :: moveRR{source=eax, output=esi, opSize=polyWordOpSize} ::
                        moveRR{source=r8, output=ecx, opSize=polyWordOpSize} :: loadThreadId edi
                |   (X64Win, 0) => loadThreadId ecx
                |   (X64Win, 1) => moveRR{source=eax, output=edx, opSize=polyWordOpSize} :: loadThreadId ecx
                |   (X64Win, 2) =>
                        moveRR{source=eax, output=edx, opSize=polyWordOpSize} ::
                        moveRR{source=mlArg2Reg, output=r8, opSize=polyWordOpSize} :: loadThreadId ecx
                |   (X64Win, 3) =>
                        moveRR{source=eax, output=edx, opSize=polyWordOpSize} :: moveRR{source=r8, output=r9, opSize=polyWordOpSize} ::
                        moveRR{source=mlArg2Reg, output=r8, opSize=polyWordOpSize} :: loadThreadId ecx
                |   (X86_32, 0) => [ PushToStack(MemoryArg{base=ebp, offset=memRegThreadSelf, index=NoIndex}) ]
                |   (X86_32, 1) => [ pushR eax, PushToStack(MemoryArg{base=ebp, offset=memRegThreadSelf, index=NoIndex}) ]
                |   (X86_32, 2) => [ pushR mlArg2Reg, pushR eax, PushToStack(MemoryArg{base=ebp, offset=memRegThreadSelf, index=NoIndex}) ]
                |   (X86_32, 3) =>
                        [
                            (* We need to move an argument from the ML stack. *)
                            PushToStack(MemoryArg{base=edi, offset=4, index=NoIndex}), pushR mlArg2Reg, pushR eax,
                            PushToStack(MemoryArg{base=ebp, offset=memRegThreadSelf, index=NoIndex})
                        ]
                |   _ => raise InternalError "rtsCall: Abi/argument count not implemented"
            ) @
            [
                CallFunction(DirectReg entryPtrReg), (* Call the function *)
                loadMemory(esp, ebp, memRegStackPtr, nativeWordOpSize) (* Restore the ML stack pointer. *)
            ] @
            (
            if targetArch <> Native32Bit then [loadMemory(r15, ebp, memRegLocalMPointer, nativeWordOpSize) ] (* Copy back the heap ptr *)
            else []
            ) @
            [
                ArithMemConst{opc=CMP, address={offset=memRegExceptionPacket, base=ebp, index=NoIndex}, source=noException, opSize=polyWordOpSize},
                ConditionalBranch{test=JNE, label=exLabel},
                (* Remove any arguments that have been passed on the stack. *)
                ReturnFromFunction(Int.max(case abi of X86_32 => nArgs-2 | _ => nArgs-5, 0)),
                JumpLabel exLabel, (* else raise the exception *)
                loadMemory(eax, ebp, memRegExceptionPacket, polyWordOpSize),
                RaiseException { workReg=ecx }
            ]
 
        val profileObject = createProfileObject functionName
        val newCode = codeCreate (functionName, profileObject, debugSwitches)
        val closure = makeConstantClosure()
        val () = X86OPTIMISE.generateCode{code=newCode, labelCount=1(*One label.*), ops=code, resultClosure=closure}
    in
        closureAsAddress closure
    end

    (* This is a quicker version but can only be used if the RTS entry does
       not allocated ML memory, raise an exception or need to suspend the thread. *)
    datatype fastArgs = FastArgFixed | FastArgDouble | FastArgFloat


    fun rtsCallFastGeneral (functionName, argFormats, (*resultFormat*) _, debugSwitches) =
    let
        val entryPointAddr = makeEntryPoint functionName

        (* Get the ABI.  On 64-bit Windows and Unix use different calling conventions. *)
        val abi = getABI()

        val (entryPtrReg, saveMLStackPtrReg) =
            if targetArch <> Native32Bit then (r11, r13) else (ecx, edi)
        
        val stackSpace =
            case abi of
                X64Unix => memRegSize
            |   X64Win => memRegSize + 32 (* Requires 32-byte save area. *)
            |   X86_32 =>
                let
                    (* GCC likes to keep the stack on a 16-byte alignment. *)
                    val argSpace = List.foldl(fn (FastArgDouble, n) => n+8 | (_, n) => n+4) 0 argFormats
                    val align = argSpace mod 16
                in
                    (* Add sufficient space so that esp will be 16-byte aligned *)
                    if align = 0
                    then memRegSize
                    else memRegSize + 16 - align
                end

        (* The number of ML arguments passed on the stack. *)
        val mlArgsOnStack =
            Int.max(case abi of X86_32 => List.length argFormats - 2 | _ => List.length argFormats - 5, 0)

        val code =
            [
                Move{source=AddressConstArg entryPointAddr, destination=RegisterArg entryPtrReg, moveSize=opSizeToMove polyWordOpSize}, (* Load the entry point ref. *)
                loadHeapMemory(entryPtrReg, entryPtrReg, 0, nativeWordOpSize),(* Load its value. *)
                moveRR{source=esp, output=saveMLStackPtrReg, opSize=nativeWordOpSize}, (* Save ML stack and switch to C stack. *)
                loadMemory(esp, ebp, memRegCStackPtr, nativeWordOpSize),
                (* Set the stack pointer past the data on the stack.  For Windows/64 add in a 32 byte save area *)
                ArithToGenReg{opc=SUB, output=esp, source=NonAddressConstArg(LargeInt.fromInt stackSpace), opSize=nativeWordOpSize}
            ] @
            (
                case (abi, argFormats) of  (* Set the argument registers. *)
                    (_, []) => []
                |   (X64Unix, [FastArgFixed]) => [ moveRR{source=eax, output=edi, opSize=polyWordOpSize} ]
                |   (X64Unix, [FastArgFixed, FastArgFixed]) =>
                        (* Since mlArgs2Reg is esi on 32-in-64 this is redundant. *)
                        [ moveRR{source=mlArg2Reg, output=esi, opSize=polyWordOpSize}, moveRR{source=eax, output=edi, opSize=polyWordOpSize} ]
                |   (X64Unix, [FastArgFixed, FastArgFixed, FastArgFixed]) => 
                        [ moveRR{source=mlArg2Reg, output=esi, opSize=polyWordOpSize}, moveRR{source=eax, output=edi, opSize=polyWordOpSize},
                          moveRR{source=r8, output=edx, opSize=polyWordOpSize} ]
                |   (X64Unix, [FastArgFixed, FastArgFixed, FastArgFixed, FastArgFixed]) => 
                        [ moveRR{source=mlArg2Reg, output=esi, opSize=polyWordOpSize}, moveRR{source=eax, output=edi, opSize=polyWordOpSize},
                          moveRR{source=r8, output=edx, opSize=polyWordOpSize}, moveRR{source=r9, output=ecx, opSize=polyWordOpSize} ]
                |   (X64Win, [FastArgFixed]) => [ moveRR{source=eax, output=ecx, opSize=polyWordOpSize} ]
                |   (X64Win, [FastArgFixed, FastArgFixed]) => [ moveRR{source=eax, output=ecx, opSize=polyWordOpSize}, moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize} ]
                |   (X64Win, [FastArgFixed, FastArgFixed, FastArgFixed]) =>
                        [ moveRR{source=eax, output=ecx, opSize=polyWordOpSize}, moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize} (* Arg3 is already in r8. *) ]
                |   (X64Win, [FastArgFixed, FastArgFixed, FastArgFixed, FastArgFixed]) =>
                        [ moveRR{source=eax, output=ecx, opSize=polyWordOpSize}, moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize} (* Arg3 is already in r8 and arg4 in r9. *) ]
                |   (X86_32, [FastArgFixed]) => [ pushR eax ]
                |   (X86_32, [FastArgFixed, FastArgFixed]) => [ pushR mlArg2Reg, pushR eax ]
                |   (X86_32, [FastArgFixed, FastArgFixed, FastArgFixed]) =>
                        [
                            (* We need to move an argument from the ML stack. *)
                            loadMemory(edx, saveMLStackPtrReg, 4, polyWordOpSize), pushR edx, pushR mlArg2Reg, pushR eax
                        ]
                |   (X86_32, [FastArgFixed, FastArgFixed, FastArgFixed, FastArgFixed]) =>
                        [
                            (* We need to move an arguments from the ML stack. *)
                            loadMemory(edx, saveMLStackPtrReg, 4, polyWordOpSize), pushR edx,
                            loadMemory(edx, saveMLStackPtrReg, 8, polyWordOpSize), pushR edx,
                            pushR mlArg2Reg, pushR eax
                        ]

                    (* One "double" argument.  The value needs to be unboxed. *)
                |   (X86_32, [FastArgDouble]) =>
                     (* eax contains the address of the value.  This must be unboxed onto the stack. *)
                    [
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=DoublePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 8, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=DoublePrecision, andPop=true }
                    ]

                |   (_, [FastArgDouble]) => [ (* Already in xmm0 *) ]

                |   (X86_32, [FastArgDouble, FastArgDouble]) =>
                     (* eax and ebx contain the addresses of the values.  They must be unboxed onto the stack. *)
                    [
                        FPLoadFromMemory{address={base=ebx, offset=0, index=NoIndex}, precision=DoublePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 8, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=DoublePrecision, andPop=true },
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=DoublePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 8, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=DoublePrecision, andPop=true }
                    ]
                    (* X64 on both Windows and Unix take the first arg in xmm0 and the second in xmm1. They are already there. *)
                |   (_, [FastArgDouble, FastArgDouble]) => [ ]

                    (* X64 on both Windows and Unix take the first arg in xmm0.  On Unix the integer argument is treated
                       as the first argument and goes into edi.  On Windows it's treated as the second and goes into edx.
                       N.B.  It's also the first argument in ML so is in rax. *)
                |   (X64Unix, [FastArgDouble, FastArgFixed]) => [ moveRR{source=eax, output=edi, opSize=nativeWordOpSize} ]
                |   (X64Win, [FastArgDouble, FastArgFixed]) => [ moveRR{source=eax, output=edx, opSize=nativeWordOpSize} ]
                |   (X86_32, [FastArgDouble, FastArgFixed]) =>
                     (* ebx must be pushed to the stack but eax must be unboxed.. *)
                    [
                        pushR ebx,
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=DoublePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 8, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=DoublePrecision, andPop=true }
                    ]

                    (* One "float" argument.  The value needs to be untagged on X86/64 but unboxed on X86/32. *)
                |   (X86_32, [FastArgFloat]) =>
                     (* eax contains the address of the value.  This must be unboxed onto the stack. *)
                    [
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=SinglePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 4, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=SinglePrecision, andPop=true }
                    ]
                |   (_, [FastArgFloat]) => []

                    (* Two float arguments.  Untag them on X86/64 but unbox on X86/32 *)
                |   (X86_32, [FastArgFloat, FastArgFloat]) =>
                     (* eax and ebx contain the addresses of the values.  They must be unboxed onto the stack. *)
                    [
                        FPLoadFromMemory{address={base=ebx, offset=0, index=NoIndex}, precision=SinglePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 4, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=SinglePrecision, andPop=true },
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=SinglePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 4, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=SinglePrecision, andPop=true }
                    ]
                |   (_, [FastArgFloat, FastArgFloat]) => [] (* Already in xmm0 and xmm1 *)

                    (* One float argument and one fixed. *)
                |   (X64Unix, [FastArgFloat, FastArgFixed]) => [moveRR{source=mlArg2Reg, output=edi, opSize=polyWordOpSize} ]
                |   (X64Win, [FastArgFloat, FastArgFixed]) => [moveRR{source=mlArg2Reg, output=edx, opSize=polyWordOpSize}]
                |   (X86_32, [FastArgFloat, FastArgFixed]) =>
                     (* ebx must be pushed to the stack but eax must be unboxed.. *)
                    [
                        pushR ebx,
                        FPLoadFromMemory{address={base=eax, offset=0, index=NoIndex}, precision=SinglePrecision},
                        ArithToGenReg{ opc=SUB, output=esp, source=NonAddressConstArg 4, opSize=nativeWordOpSize},
                        FPStoreToMemory{ address={base=esp, offset=0, index=NoIndex}, precision=SinglePrecision, andPop=true }
                    ]

                |   _ => raise InternalError "rtsCall: Abi/argument count not implemented"
            ) @
            [
                CallFunction(DirectReg entryPtrReg), (* Call the function *)
                moveRR{source=saveMLStackPtrReg, output=esp, opSize=nativeWordOpSize}, (* Restore the ML stack pointer *)
                (* Since this is an ML function we need to remove any ML stack arguments. *)
                ReturnFromFunction mlArgsOnStack
            ]
 
        val profileObject = createProfileObject functionName
        val newCode = codeCreate (functionName, profileObject, debugSwitches)
        val closure = makeConstantClosure()
        val () = X86OPTIMISE.generateCode{code=newCode, labelCount=0, ops=code, resultClosure=closure}
    in
        closureAsAddress closure
    end
    
    
    fun rtsCallFast (functionName, nArgs, debugSwitches) =
        rtsCallFastGeneral (functionName, List.tabulate(nArgs, fn _ => FastArgFixed), FastArgFixed, debugSwitches)
    
    (* RTS call with one double-precision floating point argument and a floating point result. *)
    fun rtsCallFastRealtoReal (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgDouble], FastArgDouble, debugSwitches)
    
    (* RTS call with two double-precision floating point arguments and a floating point result. *)
    fun rtsCallFastRealRealtoReal (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgDouble, FastArgDouble], FastArgDouble, debugSwitches)

    (* RTS call with one double-precision floating point argument, one fixed point argument and a
       floating point result. *)
    fun rtsCallFastRealGeneraltoReal (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgDouble, FastArgFixed], FastArgDouble, debugSwitches)

    (* RTS call with one general (i.e. ML word) argument and a floating point result.
       This is used only to convert arbitrary precision values to floats. *)
    fun rtsCallFastGeneraltoReal (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgFixed], FastArgDouble, debugSwitches)

    (* Operations on Real32.real values. *)

    fun rtsCallFastFloattoFloat (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgFloat], FastArgFloat, debugSwitches)
    
    fun rtsCallFastFloatFloattoFloat (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgFloat, FastArgFloat], FastArgFloat, debugSwitches)

    (* RTS call with one double-precision floating point argument, one fixed point argument and a
       floating point result. *)
    fun rtsCallFastFloatGeneraltoFloat (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgFloat, FastArgFixed], FastArgFloat, debugSwitches)

    (* RTS call with one general (i.e. ML word) argument and a floating point result.
       This is used only to convert arbitrary precision values to floats. *)
    fun rtsCallFastGeneraltoFloat (functionName, debugSwitches) =
        rtsCallFastGeneral (functionName, [FastArgFixed], FastArgFloat, debugSwitches)


    datatype ffiABI =
        FFI_SYSV        (* Unix 32 bit and Windows GCC 32-bit *)
    |   FFI_STDCALL     (* Windows 32-bit system ABI.  Callee clears the stack. *)
    |   FFI_MS_CDECL    (* VS 32-bit.  Same as SYSV except when returning a struct. *)
    |   FFI_WIN64       (* Windows 64 bit *)
    |   FFI_UNIX64      (* Unix 64 bit. libffi also implements this on X86/32. *)
    (* We don't include various other 32-bit Windows ABIs. *)

    local
        (* Get the current ABI list.  N.B.  Foreign.LibFFI.abiList is the ABIs on the platform we built
           the compiler on, not necessarily the one we're running on. *)
        val ffiGeneral = RunCall.rtsCallFull2 "PolyFFIGeneral"
    in
        fun getFFIAbi abi =
        let
            val abis: (string * Foreign.LibFFI.abi) list = ffiGeneral (50, ())
        in
            case List.find (fn ("default", _) => false | (_, a) => a = abi) abis of
                SOME ("sysv", _)        => FFI_SYSV
            |   SOME ("stdcall", _)     => FFI_STDCALL
            |   SOME ("ms_cdecl", _)    => FFI_MS_CDECL
            |   SOME ("win64", _)       => FFI_WIN64
            |   SOME ("unix64", _)      => FFI_UNIX64
            |   _   => raise Foreign.Foreign "Unknown or unsupported ABI"
        end
    end
    
    fun alignUp(s, align) = Word.andb(s + align-0w1, ~ align)
    fun alignUpInt(s, align) = Word.toInt(alignUp(Word.fromInt s, align))
    

    (* Build a foreign call function.  The arguments are the abi, the list of argument types and the result type.
       The result is the code of the ML function that takes three arguments: the C function to call, the arguments
       as a vector of C values and the address of the memory for the result. *)
    fun foreignCall(abivalue: Foreign.LibFFI.abi, args: Foreign.LibFFI.ffiType list, result: Foreign.LibFFI.ffiType): Address.machineWord =
    let
        val abi = getFFIAbi abivalue
        local
            val argSpace = 0
        in
            val stackSpace =
                alignUpInt(argSpace, 0w16) + (case abi of FFI_WIN64 => 32 | _ => 0) (* Add extra 32 bytes for Win 64*)
        end
        (* Register to hold the entry point. *)
        val entryPtrReg = case abi of FFI_WIN64 => r11 | FFI_UNIX64 => r11 | _ => ecx
        val code =
            [
                (* The entry point is in a SysWord.word value in RAX. *)
                loadHeapMemory(entryPtrReg, eax, 0, nativeWordOpSize)(* Load its value. *)
            ] @
            (
                (* Save heap ptr.  This is in r15 in X86/64.  Needed in case we have a callback. *)
                if targetArch <> Native32Bit
                then
                [
                    storeMemory(r15, ebp, memRegLocalMPointer, nativeWordOpSize), (* Save heap ptr *)
                    PushToStack(RegisterArg r8) (* Push the third argument. *)
                ]
                else []
            ) @
            [
                (* Save the stack pointer. *)
                storeMemory(esp, ebp, memRegStackPtr, nativeWordOpSize), (* Save ML stack and switch to C stack. *)
                loadMemory(esp, ebp, memRegCStackPtr, nativeWordOpSize)  (* Load the saved C stack pointer. *)
            ] @
            (
                (* Set the stack pointer past the data on the stack.  *)
                if stackSpace = 0
                then []
                else [ArithToGenReg{opc=SUB, output=esp, source=NonAddressConstArg(LargeInt.fromInt stackSpace), opSize=nativeWordOpSize}]
            ) @
            [
                CallFunction(DirectReg entryPtrReg), (* Call the function.  We don't need to clean up the stack. *)
                loadMemory(esp, ebp, memRegStackPtr, nativeWordOpSize) (* Restore the ML stack pointer. *)
            ] @
            [
                (* Store the result in the result area.  The third argument is a LargeWord value that contains
                   the address of a piece of C memory where the result is to be stored. *)
                if targetArch = Native32Bit
                then loadMemory(ecx, esp, 4, nativeWordOpSize)
                else PopR ecx,
                loadHeapMemory(ecx, ecx, 0, nativeWordOpSize),
                (* TODO: This is a temporary solution.  The actual return sequence depends on the
                   result type. *)
                storeMemory(eax, ecx, 0, nativeWordOpSize),
                ReturnFromFunction (if targetArch = Native32Bit then 1 else 0)
            ]
        val functionName = "foreignCall"
        val debugSwitches =
            [Universal.tagInject Pretty.compilerOutputTag (Pretty.prettyPrint(print, 70)),
               Universal.tagInject DEBUG.assemblyCodeTag true]
        val profileObject = createProfileObject functionName
        val newCode = codeCreate (functionName, profileObject, debugSwitches)
        val closure = makeConstantClosure()
        val () = X86OPTIMISE.generateCode{code=newCode, labelCount=1(*One label.*), ops=code, resultClosure=closure}
    in
        closureAsAddress closure
    end

    (* Build a callback function.  The arguments are the abi, the list of argument types and the result type.
       The result is an ML function that takes an ML function, f, as its argument, registers it as a callback and
       returns the C function as its result.  When the C function is called the arguments are copied into
       temporary memory and the vector passed to f along with the address of the memory for the result.
       "f" stores the result in it when it returns and the result is then passed back as the result of the
       callback. *)
    fun buildCallBack(abivalue: Foreign.LibFFI.abi, args: Foreign.LibFFI.ffiType list, result: Foreign.LibFFI.ffiType): Address.machineWord =
    let
        val abi = getFFIAbi abivalue
    in
        raise Fail "TODO: foreignCall"
    end

end;
