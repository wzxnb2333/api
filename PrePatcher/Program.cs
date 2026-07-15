using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;
using MethodAttributes = Mono.Cecil.MethodAttributes;

namespace Prepatcher
{
    // ReSharper disable once ClassNeverInstantiated.Global
    internal class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--mmhook")
            {
                if (args.Length != 3)
                {
                    Console.Error.WriteLine("Usage: PrePatcher.exe --mmhook <target-mmhook.dll> <source-mmhook.dll>");
                    return 2;
                }

                return PatchMMHook(args[1], args[2]);
            }

            if (args.Length < 2)
            {
                Console.Error.WriteLine("Usage: PrePatcher.exe <Original> <Patched>");
                return 2;
            }

            int changes = 0;

            using ModuleDefinition module = ModuleDefinition.ReadModule(args[0]);
            
            TypeDefinition pd = module.GetType("", "PlayerData");

            MethodDefinition pdGetBool = pd.Methods.First(method => method.Name == "GetBool");
            MethodDefinition pdSetBool = pd.Methods.First(method => method.Name == "SetBool");

            MethodDefinition pdGetFloat = pd.Methods.First(method => method.Name == "GetFloat");
            MethodDefinition pdSetFloat = pd.Methods.First(method => method.Name == "SetFloat");

            MethodDefinition pdGetInt = pd.Methods.First(method => method.Name == "GetInt");
            MethodDefinition pdSetInt = pd.Methods.First(method => method.Name == "SetInt");

            MethodDefinition pdGetString = pd.Methods.First(method => method.Name == "GetString");
            MethodDefinition pdSetString = pd.Methods.First(method => method.Name == "SetString");

            MethodDefinition pdGetVector3 = pd.Methods.First(method => method.Name == "GetVector3");
            MethodDefinition pdSetVector3 = pd.Methods.First(method => method.Name == "SetVector3");

            MethodDefinition pdGetVariable = pd.Methods.First(method => method.Name == "GetVariable");
            MethodDefinition pdSetVariable = pd.Methods.First(method => method.Name == "SetVariable");

            MethodDefinition setBoolSwappedArgs = GenerateSwappedMethod(pd, pdSetBool);
            MethodDefinition setFloatSwappedArgs = GenerateSwappedMethod(pd, pdSetFloat);
            MethodDefinition setIntSwappedArgs = GenerateSwappedMethod(pd, pdSetInt);
            MethodDefinition setStringSwappedArgs = GenerateSwappedMethod(pd, pdSetString);
            MethodDefinition setVector3SwappedArgs = GenerateSwappedMethod(pd, pdSetVector3);
            MethodDefinition setVariableSwappedArgs = GenerateSwappedMethod(pd, pdSetVariable);

            foreach (TypeDefinition type in module.Types.Where(type => type.HasMethods))
            {
                foreach (MethodDefinition method in GetMethodsRecursively(type))
                {
                    if
                    (
                        !method.HasBody
                        || method.DeclaringType == pd
                        && (method.Name == "SetupNewPlayerData" || method.Name == "AddGGPlayerDataOverrides")
                    )
                        continue;

                    ILProcessor il = method.Body.GetILProcessor();
                    
                    // Replace short branches with normal branches, etc.
                    // This ensures that inserting instructions won't cause
                    // short branch offsets to overflow and become null
                    method.Body.SimplifyMacros();

                    bool changesFound = true;

                    while (changesFound)
                    {
                        changesFound = false;

                        foreach (Instruction instr in il.Body.Instructions)
                        {
                            if (instr.Operand is not FieldReference field || field.DeclaringType != pd)
                                continue;

                            if (instr.OpCode == OpCodes.Ldfld)
                            {
                                SwapLdFld
                                (
                                    field,
                                    module,
                                    pdGetBool,
                                    pdGetFloat,
                                    pdGetInt,
                                    pdGetString,
                                    pdGetVector3,
                                    pdGetVariable,
                                    instr,
                                    il
                                );

                                changes++;
                                changesFound = true;

                                break;
                            }

                            // ReSharper disable once InvertIf
                            if (instr.OpCode == OpCodes.Stfld)
                            {
                                SwapStFld
                                (
                                    field,
                                    module,
                                    setBoolSwappedArgs,
                                    setFloatSwappedArgs,
                                    setIntSwappedArgs,
                                    setStringSwappedArgs,
                                    setVector3SwappedArgs,
                                    setVariableSwappedArgs,
                                    instr,
                                    il
                                );

                                changes++;
                                changesFound = true;

                                break;
                            }
                        }
                    }
                    
                    // After inserting instructions, replace branches
                    // with short branches where possible for optimization
                    method.Body.OptimizeMacros();
                }
            }

            module.Write(args[1]);

            Console.WriteLine("Changed " + changes + " get/set calls");
            return 0;
        }

        private static int PatchMMHook(string targetPath, string sourcePath)
        {
            string targetFull = Path.GetFullPath(targetPath);
            string sourceFull = Path.GetFullPath(sourcePath);
            string tempPath = targetFull + ".tmp." + Guid.NewGuid().ToString("N");

            if (!File.Exists(targetFull))
            {
                Console.Error.WriteLine("Target MMHOOK not found: " + targetFull);
                return 2;
            }
            if (!File.Exists(sourceFull))
            {
                Console.Error.WriteLine("Source MMHOOK not found: " + sourceFull);
                return 2;
            }
            if (string.Equals(targetFull, sourceFull, StringComparison.OrdinalIgnoreCase))
            {
                Console.Error.WriteLine("Target and source MMHOOK must be different files.");
                return 2;
            }

            try
            {
                using DefaultAssemblyResolver resolver = new();
                resolver.AddSearchDirectory(Path.GetDirectoryName(targetFull));
                resolver.AddSearchDirectory(Path.GetDirectoryName(sourceFull));
                ReaderParameters readerParameters = new() { AssemblyResolver = resolver };
                int added;

                using (ModuleDefinition target = ModuleDefinition.ReadModule(targetFull, readerParameters))
                using (ModuleDefinition source = ModuleDefinition.ReadModule(sourceFull, readerParameters))
                {
                    TypeDefinition[] missingTypes = source.Types
                        .Where(type => type.IsPublic)
                        .Where(type => target.GetType(type.Namespace, type.Name) == null)
                        .Where(type => target.ExportedTypes.All(exported =>
                            exported.Namespace != type.Namespace || exported.Name != type.Name))
                        .ToArray();

                    if (missingTypes.Length == 0)
                    {
                        Console.WriteLine("Added 0 type forwarders from " + Path.GetFileName(sourceFull)
                            + " into " + Path.GetFileName(targetFull));
                        return 0;
                    }

                    AssemblyNameReference sourceReference = target.AssemblyReferences.FirstOrDefault(reference =>
                        reference.Name == source.Assembly.Name.Name
                        && reference.Version == source.Assembly.Name.Version);
                    if (sourceReference == null)
                    {
                        sourceReference = new AssemblyNameReference(source.Assembly.Name.Name, source.Assembly.Name.Version)
                        {
                            Culture = source.Assembly.Name.Culture,
                            PublicKeyToken = source.Assembly.Name.PublicKeyToken
                        };
                        target.AssemblyReferences.Add(sourceReference);
                    }

                    foreach (TypeDefinition type in missingTypes)
                    {
                        ExportedType exported = new(type.Namespace, type.Name, target, sourceReference)
                        {
                            Attributes = Mono.Cecil.TypeAttributes.Forwarder
                        };
                        target.ExportedTypes.Add(exported);
                    }

                    added = missingTypes.Length;
                    target.Write(tempPath);
                }

                File.Replace(tempPath, targetFull, null);
                Console.WriteLine("Added " + added + " type forwarders from " + Path.GetFileName(sourceFull)
                    + " into " + Path.GetFileName(targetFull));
                return 0;
            }
            catch (Exception exception)
            {
                Console.Error.WriteLine("MMHOOK forwarding failed: " + exception);
                return 1;
            }
            finally
            {
                if (File.Exists(tempPath))
                    File.Delete(tempPath);
            }
        }

        /// <summary>
        /// Yields all methods defined on the given type, or a (recursively) nested type within the given type
        /// </summary>
        private static IEnumerable<MethodDefinition> GetMethodsRecursively(TypeDefinition type)
        {
            if (type.HasMethods)
            {
                foreach (MethodDefinition method in type.Methods)
                {
                    yield return method;
                }
            }

            if (type.HasNestedTypes)
            {
                foreach (TypeDefinition nested in type.NestedTypes)
                {
                    foreach (MethodDefinition method in GetMethodsRecursively(nested))
                    {
                        yield return method;
                    }
                }
            }
        }

        private static void SwapStFld
        (
            FieldReference field,
            ModuleDefinition module,
            MethodReference setBoolSwappedArgs,
            MethodReference setFloatSwappedArgs,
            MethodReference setIntSwappedArgs,
            MethodReference setStringSwappedArgs,
            MethodReference setVector3SwappedArgs,
            MethodReference setVariableSwappedArgs,
            Instruction instr,
            ILProcessor il
        )
        {
            var ldstr = Instruction.Create(OpCodes.Ldstr, field.Name);

            Instruction callSet;

            if (field.FieldType == module.TypeSystem.Boolean)
            {
                callSet = Instruction.Create(OpCodes.Callvirt, setBoolSwappedArgs);
            }
            else if (field.FieldType == module.TypeSystem.Single)
            {
                callSet = Instruction.Create(OpCodes.Callvirt, setFloatSwappedArgs);
            }
            else if (field.FieldType == module.TypeSystem.Int32)
            {
                callSet = Instruction.Create(OpCodes.Callvirt, setIntSwappedArgs);
            }
            else if (field.FieldType == module.TypeSystem.String)
            {
                callSet = Instruction.Create(OpCodes.Callvirt, setStringSwappedArgs);
            }
            else if (field.FieldType.Name == "Vector3")
            {
                callSet = Instruction.Create(OpCodes.Callvirt, setVector3SwappedArgs);
            }
            else
            {
                var generic = new GenericInstanceMethod(setVariableSwappedArgs);
                generic.GenericArguments.Add(field.FieldType);
                callSet = Instruction.Create(OpCodes.Callvirt, generic);
            }
            
            il.InsertAfter(instr, callSet);

            instr.OpCode = ldstr.OpCode;
            instr.Operand = ldstr.Operand;
        }

        private static void SwapLdFld
        (
            FieldReference field,
            ModuleDefinition module,
            MethodReference pdGetBool,
            MethodReference pdGetFloat,
            MethodReference pdGetInt,
            MethodReference pdGetString,
            MethodReference pdGetVector3,
            MethodReference pdGetVariable,
            Instruction instr,
            ILProcessor il
        )
        {
            var ldstr = Instruction.Create(OpCodes.Ldstr, field.Name);

            Instruction callGet;

            if (field.FieldType == module.TypeSystem.Boolean)
            {
                callGet = Instruction.Create(OpCodes.Callvirt, pdGetBool);
            }
            else if (field.FieldType == module.TypeSystem.Single)
            {
                callGet = Instruction.Create(OpCodes.Callvirt, pdGetFloat);
            }
            else if (field.FieldType == module.TypeSystem.Int32)
            {
                callGet = Instruction.Create(OpCodes.Callvirt, pdGetInt);
            }
            else if (field.FieldType == module.TypeSystem.String)
            {
                callGet = Instruction.Create(OpCodes.Callvirt, pdGetString);
            }
            else if (field.FieldType.Name == "Vector3")
            {
                callGet = Instruction.Create(OpCodes.Callvirt, pdGetVector3);
            }
            else
            {
                var generic = new GenericInstanceMethod(pdGetVariable);
                generic.GenericArguments.Add(field.FieldType);
                callGet = Instruction.Create(OpCodes.Callvirt, generic);
            }
            
            il.InsertAfter(instr, callGet);

            instr.OpCode = ldstr.OpCode;
            instr.Operand = ldstr.Operand;
        }

        private static MethodDefinition GenerateSwappedMethod(TypeDefinition methodParent, MethodReference oldMethod)
        {
            MethodDefinition swapped = new
            (
                oldMethod.Name + "SwappedArgs",
                MethodAttributes.Assembly | MethodAttributes.HideBySig,
                methodParent.Module.TypeSystem.Void
            );

            ParameterDefinition[] @params = oldMethod.Parameters.ToArray();

            Debug.Assert(@params.Length == 2);

            swapped.Parameters.Add
            (
                new ParameterDefinition(@params[1].ParameterType)
                {
                    Name = "value"
                }
            );
            swapped.Parameters.Add
            (
                new ParameterDefinition(@params[0].ParameterType)
                {
                    Name = "name"
                }
            );

            if (oldMethod.HasGenericParameters)
            {
                int paramCount = 0;
                foreach (GenericParameter _ in oldMethod.GenericParameters)
                {
                    swapped.GenericParameters.Add(new GenericParameter(swapped) { Name = "T" + paramCount });
                    paramCount++;
                }
            }

            ILProcessor swappedIL = swapped.Body.GetILProcessor();

            swappedIL.Emit(OpCodes.Ldarg_0);
            swappedIL.Emit(OpCodes.Ldarg_2);
            swappedIL.Emit(OpCodes.Ldarg_1);

            if (oldMethod.ContainsGenericParameter)
            {
                GenericInstanceMethod generic = new(oldMethod);

                foreach (GenericParameter param in swapped.GenericParameters)
                    generic.GenericArguments.Add(param);

                swappedIL.Emit(OpCodes.Call, generic);
            }
            else
            {
                swappedIL.Emit(OpCodes.Call, oldMethod);
            }

            swappedIL.Emit(OpCodes.Ret);

            methodParent.Methods.Add(swapped);

            return swapped;
        }
    }
}
