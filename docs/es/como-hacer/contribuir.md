# Contribuir

1. Crea una rama de trabajo.
2. Haz cambios pequenos y enfocados.
3. Actualiza docs cuando cambie API o comportamiento.
4. Ejecuta todo antes del PR:

```bash
./scripts/test-all.sh
```

Checklist:

- tests unitarios OK
- tests integracion OK
- README y docs actualizados
- sin secretos hardcodeados
- politicas de metodos (`invoke.methods`) reflejadas en gateway y OpenAPI
